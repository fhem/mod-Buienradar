## no critic

use lib q{./lib};
use warnings FATAL => 'all';
use strict;
use FHEM::Weather::Buienradar;
use GPUtils;
use English q{-no_match_vars};

sub Buienradar_Initialize {
    return FHEM::Weather::Buienradar::initialize_module(@ARG);
}

1;