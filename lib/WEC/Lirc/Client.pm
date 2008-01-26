package WEC::Lirc::Client;
use 5.006001;
use strict;
use warnings;
use Carp;
use POSIX qw(ENOENT EISDIR);
use FindBin qw($Script);

our $VERSION = "0.01";
our @CARP_NOT	= qw(WEC::FieldClient WEC::Lirc::Connection);

use WEC::Lirc::Connection;
use WEC::Lirc::Constants qw(PORT SOCKET LIRCRC_USER_FILE LIRCRC_ROOT_FILE);

use base   qw(WEC::Client);

our %lircrc_flags =
    (once	=> 1,
     quit	=> 1,
     mode	=> 1,
     startup_mode =>1);

my $default_options = {
    %{__PACKAGE__->SUPER::client_options},
    Callback	=> undef,
    ConfigFile	=> undef,
    Program	=> undef,
    StartMode	=> undef,
    ServerHup	=> undef,
};

sub default_options {
    return $default_options;
}

sub connection_class {
    return "WEC::Lirc::Connection::Client";
}

sub tilde {
    defined(my $file = shift) || croak "Undefined file";
    my ($user, $rest) = $file =~ m!^~([^/]*)(.*)\z!s or return $file;
    if ($user ne "") {
        my @pw = getpwnam($user) or croak "Could not find user $user";
        $user = $pw[7];
    } elsif (!defined($user = $ENV{HOME})) {
        my @pw = getpwuid($>) or
            croak "Could not determine who you are";
        $user = $pw[7];
    }
    croak "Home directory is the empty string" if $user eq "";
    $user =~ s!/*\z!$rest!;
    $user = "/" if $user eq "";
    # Restore taintedness
    return $user . substr($file, 0, 0);
}

sub include_config {
    my ($client, $config, $file, $caller) = @_;
    my $fh;
    if (defined ($file)) {
        $file = tilde($file);
        if ($file !~ m!\A/! && defined $caller) {
            $caller =~ s![^/]+\z!!;
            $file = $caller . $file;
        }
        open($fh, "<", $file) || croak "Could not open $file: $!";
    } elsif (open($fh, "<", tilde(LIRCRC_USER_FILE))) {
        $file = LIRCRC_USER_FILE;
    } elsif ($! != ENOENT) {
        croak "Could not open ", tilde(LIRCRC_USER_FILE), ": $!";
    } elsif (open($fh, "<", LIRCRC_ROOT_FILE)) {
        $file = LIRCRC_ROOT_FILE;
    } elsif ($! != ENOENT) {
        croak "Could not open ", LIRCRC_ROOT_FILE, ": $!";
    } else {
        croak "Could open neither ", LIRCRC_USER_FILE, " nor ", LIRCRC_ROOT_FILE, ": $!";
    }
    croak "Could not open $file: ", $! = EISDIR if -d $fh;

    # print STDERR "Parse $file\n";
    eval {
        local $_;
        local $/ = "\n";
        while (<$fh>) {
            s/\A\s+//;
            next if /\A\#|\A\z/; # Ignore comments and empty lines
            if (/\Ainclude\s+(?:"([^\"]+)"|<([^<>]+)>|(\S+))\s*/) {
                $client->include_config($config, $+, $file);
            } elsif (/\Abegin\s*\z/) {
                croak "'begin' tag while already in block" if $config->{block};
                $config->{block} = {
                    file   => $file,
                    line   => $.,
                };
            } elsif (/\Aend\s*\z/) {
                croak "'end' tag while not in block" if !$config->{block};
                my $block = delete $config->{block};
                $config->{want_mode}{$block->{mode}} ||= 1 if
                    exists $block->{mode};
                if (!exists $block->{prog}) {
                    carp("Line $block->{line} of '$block->{file}': No 'prog' entry in block");
                    next;
                }
                next if $config->{program} ne delete $block->{prog};
                croak "Flag 'once' but no 'mode' directive" if 
                    $block->{flags}{once} && !exists $block->{mode};
                if ($block->{flags}{startup_mode}) {
                    for (qw(remote button repeat delay config)) {
                        # Maybe allow config for an initial command
                        croak "'$_' makes no sense in a 'startup_mode' block"
                            if exists $block->{$_};
                    }
                    croak "Flag 'startup_mode' but no 'mode' directive" if 
                        !exists $block->{mode};
                    delete $block->{flags}{startup_mode};
                    croak("Extra flags don't make sense with 'startup_mode': ",
                          join(", ", keys %{$block->{flags}})) if 
                          %{$block->{flags}};
                    croak "Already have a startup_mode for program '$config->{program}': $config->{map}{''}{''}{$config->{program}}" if exists $config->{"map"}{""}{""}{$config->{program}};
                    $config->{"map"}{""}{""}{$config->{program}} = 
                        $block->{mode};
                } else {
                    croak "No 'button' definition" unless $block->{button};
                    delete $block->{remote};
                    $block->{delay} ||= 0;
                    $block->{nr} = $config->{nr}++;
                    push @{$config->{"map"}{$config->{mode}}{uc $block->{button}[0][0]}{uc $block->{button}[0][1]}}, $block;
                }
            } elsif (/\Abegin\s+(\S+)\s*\z/) {
                croak "'begin $1' tag while inside a block" if
                    $config->{block};
                croak "'begin $1' tag while already in mode $config->{mode}" if
                    $config->{mode} ne "";
                $config->{mode} = $1;
                $config->{"map"}{$config->{mode}} ||= {};
                $config->{have_mode}{$1} ||= 1;
            } elsif (/\Aend\s+(\S+)\s*\z/) {
                croak "'end $1' tag while inside a block" if $config->{block};
                croak "'end $1' tag while not in any mode " if
                    $config->{mode} eq "";
                croak "'end $1' tag while in mode $config->{mode}" if
                    $config->{mode} ne $1;
                $config->{mode} = "";
            } elsif (my ($tag, $val) = /\A(prog|remote|config|mode)\s*=\s*(.*\S)\s*\z/i) {
                croak "Assignment while not in block" if !$config->{block};
                $config->{block}{lc $tag} = $val;
                next;
            } elsif (($tag, $val) = /\A(delay|repeat)\s*=\s*(\d+)\s*\z/i) {
                croak "Assignment while not in block" if !$config->{block};
                $config->{block}{lc $tag} = $val;
                next;
            } elsif (my ($flags) = /\Aflags\s*=\s*(.*\S)\s*\z/i) {
                croak "Assignment while not in block" if !$config->{block};
                $flags =~ /\A[^\s|]+(?:(?:\s+|\s*\|\s*)[^\s|]+)*\z/ ||
                    croak "Could not parse flags '$flags'";
                for my $flag (split /[\s|]+/, $flags) {
                    croak "Unknown flag '$flag'" unless
                        exists $lircrc_flags{lc $flag};
                    croak "flag '$flag' while not inside a mode block" if 
                        lc $flag eq "mode" && $config->{mode} eq "";
                    croak "flag '$flag' while inside a mode block" if 
                        lc $flag eq "startup_mode" && $config->{mode} ne "";
                    croak "Duplicate flag '$flag'" if
                        exists $config->{block}{flags}{lc $flag};
                    $config->{block}{flags}{lc $flag} = 1;
                }
                next;
            } elsif (my ($button) = /\Abutton\s*=\s*(\S+)\s*\z/) {
                croak "Assignment while not in block" if !$config->{block};
                push @{$config->{block}{button}}, [exists $config->{block}{remote} ? $config->{block}{remote} : "*", $button];
                next;
            } else {
                croak "Unknown token";
            }
        }
    };
    die "Line $. of '$file': $@" if $@;
    close($fh) || die "Error closing $file: $!";
}

sub parse_config {
    my $client = shift;
    my %config =
        (block => undef,
         mode  => "",
         program => $client->program,
         want_mode => {},
         have_mode => {},
         "map" => {},
    );
    $client->include_config(\%config, @_ ?
                            shift : $client->{options}{ConfigFile});
    croak "Unfinished block" if $config{block};
    croak "Unfinished mode"  if $config{mode} ne "";
    my @bad_want;
    delete $config{have_mode}{$_} || push @bad_want, $_ for
        keys %{$config{want_mode}};
    carp("You have a rule trying to switch to non-existent mode @bad_want") if
        @bad_want;
    carp("You have an unreachable mode @{[keys %{$config{have_mode}}]}") if
        keys %{$config{have_mode}};
    return $config{map};
}

sub init {
    my ($client, $params) = @_;

    if (defined $client->{destination}) {
        $client->{destination} = "tcp://" . $client->{destination} unless
            $client->{destination} =~ m!\A\w+://!;
        $client->{destination} .= ":" . PORT if
            $client->{destination} =~ m!\Atcp://[^:]+$!i;
    } else {
        $client->{destination} = SOCKET;
    }

    $client->{options}{Config} = $client->parse_config;
}

sub program {
    my $client = shift;
    return $client->{options}{Program} if defined $client->{options}{Program};
    return $Script;
}

1;
