package WEC::Lirc::Server;
use 5.006001;
use strict;
use warnings;
use Carp;

our $VERSION = "0.01";
our @CARP_NOT	= qw(WEC::FieldServer WEC::Lirc::Connection);

use WEC::Lirc::Connection;
use WEC::Lirc::Constants qw(PORT LIRCD_FILE);

use base   qw(WEC::Server);

my $default_options = {
    %{__PACKAGE__->SUPER::server_options},
    Version	=> undef,
    ConfigFile	=> undef,
    SendOnce	=> undef,
    SendStart	=> undef,
    SendStop	=> undef,
};

sub default_options {
    return $default_options;
}

sub default_port() {
    return PORT;
}

sub connection_class {
    return "WEC::Lirc::Connection::Server";
}

sub init {
    (my $server, my $params) = @_;
    if (defined(my $version = $server->{options}{Version})) {
        utf8::downgrade($version) || croak "Wide character in $version";
        croak "Newline in Version" if $version =~ /\n/;
    }
    my $options = $server->{options};
    $options->{Config} = $server->parse_config if 
        exists $options->{ConfigFile};
}

# Following are unsupported since I have no config file example for them:
#   raw_codes
#   three
#   two
# For compatibility with WinLIRC it accepts (but ignores) transmitter
my $FLAG = qr/RC5|RC6|RCMM|SHIFT_ENC|SPACE_ENC|REVERSE|NO_HEAD_REP|NO_FOOT_REP|CONST_LENGTH|RAW_CODES|REPEAT_HEADER|SPECIAL_TRANSMITTER/;
sub parse_config {
    my $server = shift;

    my $file = @_ ? shift : $server->{options}{ConfigFile};
    $file = LIRCD_FILE unless defined $file && $file ne "";
    print STDERR "Getting $file\n";
    open(my $fh, "<", $file) || croak "Could not open $file: $!";

    my %remotes;
    eval {
        local $_;
        local $/ = "\n";
        my ($in_remote, $in_codes, $buttons, $nr);
        while (<$fh>) {
            s/\A\s+//;
            next if /\A\#|\A\z/; # Ignore comments and empty lines
            s/\s*\z//;
            if (/\Abegin\s+remote\z/) {
                croak "Already inside a remote block" if $in_remote;
                $in_remote = {
                    file  => $file,
                    line  => $.,
                    flags => {},
                    nr    => $nr++,
                };
            } elsif (/\Aend\s+remote\z/) {
                croak "Not inside a remote block" if !$in_remote;
                croak "No 'name' key" if !exists $in_remote->{name};
                croak "A remote named '$in_remote->{name}' already exists" if
                    exists $remotes{uc $in_remote->{name}};
                croak "No buttons were defined" if !$in_remote->{buttons};
                $remotes{uc $in_remote->{name}} = $in_remote;
                $in_remote = undef;
            } elsif (/\Abegin\s+codes\z/) {
                croak "Not inside a remote block" if !$in_remote;
                croak "Already inside a codes block" if $in_codes;
                $in_codes = {};
                $buttons = [];
            } elsif (/\Aend\s+codes\z/) {
                croak "Not inside a codes block" if !$in_codes;
                $in_remote->{codes}   = $in_codes;
                $in_remote->{buttons} = $buttons;
                $in_codes = undef;
            } elsif ($in_codes) {
                if (my ($button, $code) = /\A(\S+)\s+(0[xX]0*[\da-fA-F]{1,8})\z/) {
                    croak "Already have a definition for button '$button'" if
                        exists $in_codes->{$button};
                    # The regex already makes sure the value < 2**32
                    $in_codes->{$button} = oct($code);
                    push @$buttons, $button;
                } else {
                    croak "Could not parse button definition";
                }
            } elsif (/\A(name)\s+(\S+)\z/ ||
                     /\A(bits|eps|aeps|ptrail|plead|pre_data_bits|post_data_bits|gap|repeat_gap|min_repeat|toggle_bit|frequency|duty_cycle|repeat_bit)\s+(\d+)\z/) {
                croak "Not inside a remote block" if !$in_remote;
                croak "Duplicate key '$1'" if exists $in_remote->{$1};
                $in_remote->{$1} = $2;
            } elsif (/\A(pre_data|post_data|transmitter)\s+(0[xX]0*[\da-fA-F]{1,8})\z/) {
                croak "Not inside a remote block" if !$in_remote;
                croak "Duplicate key '$1'" if exists $in_remote->{$1};
                # The regex already makes sure the value < 2**32
                $in_remote->{$1} = oct($2);
            } elsif (/\Aflags\s+($FLAG(?:\s*\|\s*$FLAG)*)\z/) {
                croak "Not inside a remote block" if !$in_remote;
                for (split /\s*\|\s*/, $1) {
                    croak "Duplicate flag '$_'" if
                        exists $in_remote->{flags}{$_};
                    $in_remote->{flags}{$_} = 1;
                }
            } elsif (/\A(header|zero|one|foot|repeat|pre|post)\s+(\d+)\s+(\d+)\z/) {
                croak "Not inside a remote block" if !$in_remote;
                croak "Duplicate key '$1'" if exists $in_remote->{$1};
                $in_remote->{$1} = [$2, $3];
            } else {
                croak "Unknown token";
            }
        }
        croak "Unfinished codes section" if $in_codes;
        croak "Unfinished remote section" if $in_remote;
    };
    die "Line $. of '$file': $@" if $@;
    close($fh) || die "Error closing $file: $!";
    return \%remotes;
}

1;
