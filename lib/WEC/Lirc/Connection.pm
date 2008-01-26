package WEC::Lirc::Connection;
use 5.008;
use strict;
use warnings;

our $VERSION = "0.01";
use base qw(WEC::Connection);

package WEC::Lirc::Connection::Client;
use Carp;
use WEC::Connection qw(COMMAND ARG);

use base qw(WEC::Lirc::Connection);
# use fields qw(mode reply entered);

sub init_client {
    my $connection = shift;
    $connection->{in_process}	= \&get_line;
    $connection->{in_want}	= 1;
    $connection->{answers}	= [];
    if (defined $connection->{options}{StartMode}) {
        $connection->{mode} = $connection->{options}{StartMode};
    } else {
        my $program = $connection->{parent}->program;
        my $config = $connection->{options}{Config} ||
            croak "No Config option";
        if (defined $config->{""}{""}{$program}) {
            $connection->{mode} = $config->{""}{""}{$program};
        } elsif ($config->{$program}) {
            $connection->{mode} = $program;
        } else {
            $connection->{mode} = "";
        }
    }
}

sub get_line {
    my $connection = shift;
    my $pos = index($_, "\n", $connection->{in_want}-1);
    if ($pos < 0) {
        $connection->{in_want} = 1+length;
        return;
    }
    $connection->{in_want} = 1;
    my @line = split " ", substr($_, 0, $pos+1, "");
    if (@line == 4) {
        $line[0] =~ /\A[\da-fA-F]{16}\z/ ||
            die "Cannot parse IR code $line[0]";
        $line[1] =~ /\A[\da-fA-F]+\z/ ||
            die "Cannot parse key repeat $line[1]";
        my $repeat = 1+hex $line[1];
        # Look up remote and button under the current mode
        my $config = $connection->{options}{Config}{$connection->{mode}};
        my @match = sort {$a->{nr} <=> $b->{nr} } map { @{$_->{"*"} || []}, @{$_->{uc $line[2]} || []} } $config->{"*"} || (), $config->{uc $line[3]} || ();
        for my $match (@match) {
            # Pressed enough ?
            next if $match->{repeat} ?
                $repeat <= $match->{delay} ||
                ($repeat-$match->{delay}) % $match->{repeat} :
                ($repeat-$match->{delay}) != 1;

            # Mode leave
            if ($match->{flags}{mode}) {
                croak "Mode flag while not inside a mode" if
                    $connection->{mode} eq "";
                delete $connection->{entered}{$connection->{mode}};
                $connection->{mode} = "";
            }

            # Mode enter
            if (defined $match->{mode}) {
                if (!$connection->{entered}{$match->{mode}}) {
                    $connection->activate($match, \@line);
                    $connection->{entered}{$match->{mode}} = 1;
                } elsif (!$match->{flags}{once}) {
                    $connection->activate($match, \@line);
                }
                $connection->{mode} = $match->{mode};
            } else {
                $connection->activate($match, \@line);
            }
            last if $match->{flags}{quit};
        }
    } elsif (@line == 1) {
        $line[0] eq "BEGIN" || die "Cannot parse IR code $line[0]";
        $connection->{in_process} = \&get_reply_command;
        $connection->{reply} = {};
        return;
    } else {
        die "Cannot parse protocol message @line (wrong number of elements)";
    }
}

sub activate {
    my $connection = shift;
    my $callback = $connection->{options}{Callback} || return;
    my $match = shift;
    return if !exists $match->{config};
    if (ref($callback) eq "HASH") {
        if (!exists $callback->{$match->{config}}) {
            carp "No handler for config='$match->{config}'";
            return;
        }
        defined($callback = $callback->{$match->{config}}) || return;
    }
    $callback->($connection, $match->{config}, $match, $connection->{mode}, @_);
}

sub get_reply_command {
    my $connection = shift;
    my $pos = index($_, "\n", $connection->{in_want}-1);
    if ($pos < 0) {
        $connection->{in_want} = 1+length;
        return;
    }
    $connection->{in_want} = 1;
    chop($connection->{reply}{command} = substr($_, 0, $pos+1, ""));
    $connection->{in_process} = \&get_reply_optional;
}

sub get_reply_optional {
    my $connection = shift;
    my $pos = index($_, "\n", $connection->{in_want}+1);
    if ($pos < 0) {
        $connection->{in_want} = 1+length;
        return;
    }
    $connection->{in_want} = 1;
    my $line = substr($_, 0, $pos+1, "");
    if ($line eq "END\n") {
        $connection->{in_process} = \&get_line;
        # my $reply = delete $connection->{reply};
        my $reply = $connection->{reply};
        $connection->{reply} = undef;
        if ($reply->{command} eq "SIGHUP") {
            $connection->{options}{ServerHup}->($connection, "SIGHUP") if
                $connection->{options}{ServerHup};
        } else {
            @{$connection->{answers}} &&
                $connection->{answers}[0][COMMAND] eq $reply->{command} ||
                croak "Got an unexpected reply of type '$reply->{command}' while I expected ", @{$connection->{answers}} ? "nothing" : "'$connection->{answers}[0][COMMAND]'";
            if ($reply->{command} eq "version") {
                $reply->{status} || croak "Version command failed";
                $connection->_callback(version => @{$reply->{data}});
            } elsif ($reply->{command} eq "list") {
                $reply->{status} || croak "List command failed";
                $connection->_callback(remotes => $reply->{data});
            } elsif (my ($remote) = $reply->{command} =~ /\Alist (.*)/) {
                if (!$reply->{status}) {
                    # Failed, unknown remote
                    # Silly enough, next will come a SECOND answer,
                    # but doing a plain list
                    # Set up a fake extra expected answer
                    splice(@{$connection->{answers}}, 1, 0, 
                           [$connection->{answers}[0][0], undef, 1]);
                    $connection->_callback(-error => @{$reply->{data}});
                    return;
                }
                my $answer = shift @{$connection->{answers}};
                # Handles the fake extra list
                return if $answer->[ARG];
                my %buttons;
                for (@{$reply->{data}}) {
                    my ($code, $button) = /\A\s*([\da-fA-F]+)\s+(.*\S)\s*\z/ or
                        croak "Remote $remote: Could not parse button line $_";
                    croak "Remote $remote: Duplicate definition for button '$button'" if exists $buttons{$button};
                    $buttons{$button} = length $code < 16 ? "0" x (16-$code) . lc $code: lc $code;
                }
                $connection->_callback(buttons	=> \%buttons,
                                       remote	=> $remote,
                                       raw	=> $reply->{data});
            } elsif (my ($args) =
                     $reply->{command} =~ /\Asend_(?:once|start|stop) (.*)/) {
                if (!$reply->{status}) {
                    # Failed, can't send ?
                    $connection->_callback(-error => @{$reply->{data}});
                    return;
                }
                croak "Succesful send not implemented. I don't have the hardware to test";
            } else {
                croak "Unhandled reply type '$reply->{command}'";
            }
        }
    } elsif ($line eq "SUCCESS\n") {
        $connection->{reply}{status} = 1;
    } elsif ($line eq "ERROR\n") {
        $connection->{reply}{status} = 0;
    } elsif ($line eq "DATA\n") {
        $connection->{in_process} = \&get_reply_data_size;
    } else {
        chop $line;
        croak "Unknown optional reply key $line";
    }
}

sub get_reply_data_size {
    my $connection = shift;
    my $pos = index($_, "\n", $connection->{in_want}-1);
    if ($pos < 0) {
        $connection->{in_want} = 1+length;
        return;
    }
    $connection->{in_want} = 1;
    my $line = substr($_, 0, $pos+1, "");
    if ($line !~ /\A(\d+)\n\z/) {
        chop $line;
        croak "Cannot parse DATA size $line";
    }
    $connection->{reply}{left} = $1;
    $connection->{in_process} = $1 ? \&get_reply_data : \&get_reply_optional;
    $connection->{reply}{data} = [];
}

sub get_reply_data {
    my $connection = shift;
    while (1) {
        my $pos = index($_, "\n", $connection->{in_want}-1);
        if ($pos < 0) {
            $connection->{in_want} = 1+length;
            return;
        }
        $connection->{in_want} = 1;
        push @{$connection->{reply}{data}}, substr($_, 0, $pos+1, "");
        chop $connection->{reply}{data}[-1];
        if (--$connection->{reply}{left} == 0) {
            delete $connection->{reply}{left};
            $connection->{in_process} = \&get_reply_optional;
            return;
        }
    }
}

sub version {
    my $connection = shift;
    if ($connection->{cork}) {
        push @{$connection->{cork}}, ["version", shift];
        return;
    }
    $connection->send0 if $connection->{out_buffer} eq "";
    $connection->{out_buffer} .= "version\n";
    push @{$connection->{answers}}, ["version", shift];
}

sub remotes {
    my $connection = shift;
    if ($connection->{cork}) {
        push @{$connection->{cork}}, ["list", shift];
        return;
    }
    $connection->send0 if $connection->{out_buffer} eq "";
    $connection->{out_buffer} .= "list\n";
    push @{$connection->{answers}}, ["list", shift];
}

sub buttons {
    my ($connection, $callback, $remote) = @_;
    utf8::downgrade($remote) || croak "Wide character in remote";
    croak "Newline in remote name" if $remote =~ /\n/;
    $remote =~ /\A\S/ ||
        croak "Remote name '$remote' does not start with non-whitespace";
    $remote =~ /\S\z/ ||
        croak "Remote name '$remote' does not end with non-whitespace";
    if ($connection->{cork}) {
        push @{$connection->{cork}}, ["list $remote", $callback];
        return;
    }
    $connection->send0 if $connection->{out_buffer} eq "";
    $connection->{out_buffer} .= "list $remote\n";
    push @{$connection->{answers}}, ["list $remote", $callback];
}

sub hit {
    my ($connection, $callback, $remote, $button, $repeat) = @_;
    utf8::downgrade($remote) || croak "Wide character in remote";
    croak "Newline in remote name" if $remote =~ /\n/;
    utf8::downgrade($button) || croak "Wide character in button";
    croak "Newline in button name" if $button =~ /\n/;
    my $string = "send_once $remote $button";
    if (defined($repeat)) {
        utf8::downgrade($repeat) || croak "Wide character in repeat";
        $repeat =~ /\A(\d+)\z/ || croak "Repeat is not a natural number";
        $string .= " $repeat";
    }
    if ($connection->{cork}) {
        push @{$connection->{cork}}, [$string, $callback];
        return;
    }
    $connection->send0 if $connection->{out_buffer} eq "";
    $connection->{out_buffer} .= "$string\n";
    push @{$connection->{answers}}, [$string, $callback];
}

sub press {
    my ($connection, $callback, $remote, $button, $repeat) = @_;
    utf8::downgrade($remote) || croak "Wide character in remote";
    croak "Newline in remote name" if $remote =~ /\n/;
    utf8::downgrade($button) || croak "Wide character in button";
    croak "Newline in button name" if $button =~ /\n/;
    if ($connection->{cork}) {
        push @{$connection->{cork}}, ["send_start $remote $button", $callback];
        return;
    }
    $connection->send0 if $connection->{out_buffer} eq "";
    $connection->{out_buffer} .= "send_start $remote $button\n";
    push @{$connection->{answers}}, ["send_start $remote $button", $callback];
}

sub release {
    my ($connection, $callback, $remote, $button, $repeat) = @_;
    utf8::downgrade($remote) || croak "Wide character in remote";
    croak "Newline in remote name" if $remote =~ /\n/;
    utf8::downgrade($button) || croak "Wide character in button";
    croak "Newline in button name" if $button =~ /\n/;
    if ($connection->{cork}) {
        push @{$connection->{cork}}, ["send_stop $remote $button", $callback];
        return;
    }
    $connection->send0 if $connection->{out_buffer} eq "";
    $connection->{out_buffer} .= "send_stop $remote $button\n";
    push @{$connection->{answers}}, ["send_stop $remote $button", $callback];
}

sub uncork {
    my $connection = shift;
    croak "Not corked" unless $connection->{cork};
    croak "Cannot uncork while handshake still in progress" if
        $connection->{handshaking};
    my $cork = $connection->{cork};
    $connection->{cork} = undef;
    return if !@$cork;
    $connection->send0 if $connection->{out_buffer};
    for (@$cork) {
        push @{$connection->{answers}}, $_;
        $connection->{out_buffer} .= $_->[COMMAND] . "\n";
    }
    return;
}

package WEC::Lirc::Connection::Server;
use Carp;
use base qw(WEC::Lirc::Connection);
# use fields qw(answer_id);

sub init_server {
    my $connection = shift;
    $connection->{in_process}	= \&get_command;
    $connection->{in_want}	= 1;
    $connection->{answer_id}	= "a";
}

my %command2function =
    (send_once	=> ["SendOnce",  "hardware does not support sending"],
     send_start	=> ["SendStart", "hardware does not support sending"],
     send_stop	=> ["SendStop",  "not repeating"]);
sub get_command {
    my $connection = shift;
    my $pos = index($_, "\n", $connection->{in_want}-1);
    if ($pos < 0) {
        $connection->{in_want} = 1+length;
        return;
    }
    $connection->{in_want} = 1;
    my $command = substr($_, 0, $pos+1, "");
    my ($what, @args) = split " ", $command;
    my $answer = $connection->{answer_id};
    $answer++;
    my $function_name = "Builtin";
    if (defined $what) {
        my $todo = lc $what;
        if ($todo eq "version") {
            if (@args) {
                $connection->error($command, "bad send packet");
            } elsif (defined $connection->{options}{Version}) {
                $connection->success($command,
                                     $connection->{options}{Version});
            } else {
                $connection->success($command, "WEC::Lirc $VERSION");
            }
        } elsif ($command2function{$todo}) {
            if (my $function = $connection->{options}{$command2function{$todo}[0]}) {
                $function_name = $command2function{$todo}[0]
            } else {
                $connection->error($command, $command2function{$todo}[1]);
            }
        } elsif ($todo eq "list") {
            if (@args) {
                if ($connection->{options}{Buttons}) {
                    $function_name = "Buttons";
                } elsif (my $config = $connection->{options}{Config}) {
                    if ($config = $config->{uc $args[0]}) {
                        $connection->success($command, map {
                            sprintf("%016x %s", $config->{codes}{$_}, $_);
                        } @{$config->{buttons}});
                    } else {
                        $connection->error($command, "unknown remote: \"$args[0]\"");
                        $answer++;
                        goto REMOTES;
                    }
                } else {
                    $connection->error($command,
                                       "Unhandled directive: \"$what\"");
                }
            } else {
              REMOTES:
                if ($connection->{options}{Remotes}) {
                    $function_name = "Remotes";
                } elsif (my $config = $connection->{options}{Config}) {
                    $connection->success
                        ($command, map $_->{name}, sort {$a->{nr} <=> $b->{nr}} values %$config);
                } else {
                    $connection->error($command,
                                       "Unhandled directive: \"$what\"");
                }
            }
        } else {
            $connection->error($command, "Unknown directive: \"$what\"");
        }
    } else {
        $connection->error($command, "bad send packet");
    }
    $connection->{options}{$function_name}->
        ($connection, $command, $what, @args) if $function_name ne "Builtin";
    if ($answer ne $connection->{answer_id}) {
        croak "$function_name provided no answer for '$what'" if
            $answer gt $connection->{answer_id};
        croak "$function_name provided multiple answers for '$what'";
    }
}

sub success {
    my $connection = shift;
    $connection->{answer_id}++;
    $connection->send("BEGIN\n" . shift() . "SUCCESS\nDATA\n" .
                      (@_ ? @_ . "\n" . join("\n", @_) . "\n" : "0\n") .
                      "END\n");
}

sub error {
    my $connection = shift;
    $connection->{answer_id}++;
    $connection->send("BEGIN\n" . shift() . "ERROR\nDATA\n" .
                      (@_ ? @_ . "\n" . join("\n", @_) . "\n" : "0\n") .
                      "END\n");
}

1;
