use 5.008_001;
use strict;
use warnings;

use POSIX qw(ECONNRESET);

use WEC::Lirc::Client;
use WEC::Lirc::Server;
# use WEC::Lirc::Server;
use WEC::Lirc::Connection;
use WEC::Test (TraceLine => 0,
               Class => "WEC::Lirc", Parts => [qw(Connection Client)]);

1;
