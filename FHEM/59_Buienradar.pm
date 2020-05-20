## no critic (RequireFilenameMatchesPackage, CodeLayout::RequireTidyCode)
# #   JFTR:
#
#   ATM, it's not possible to comply to this Perl::Critic rule, because
#   the current state of the FHEM API does require this bogus XX_Name.pm convention
#
#   Perl::Tidy sucks 🗿
package FHEM::Buienradar;

use strict;
use warnings;
use HttpUtils;
use JSON;
use List::Util;
use Time::Seconds;
use POSIX;
use Data::Dumper;
use English qw( -no_match_vars );
use Storable;
use GPUtils;
use experimental qw( switch );
use 5.0101;    # we do not want perl be older than from 2007, so > 5.10.1
use Readonly;
use FHEM::Meta;

############################################################    Default values
Readonly our $VERSION               => q{3.0.7};
Readonly our $DEFAULT_INTERVAL      => ONE_MINUTE * 2;
Readonly our $DEBUGGING_MIN_VERBOSE => 4;
Readonly our $DEFAULT_REGION        => q{de};
Readonly our $DEFAULT_TEXT_BAR_CHAR => q{=};
Readonly our $DEFAULT_LANGUAGE      => q{en};
Readonly our $DEFAULT_LATITUDE      => 51.0;
Readonly our $DEFAULT_LONGITUDE     => 7.0;

############################################################    Translations
Readonly my %TRANSLATIONS => (
    'general' => {
        'unknown' => {
            'de' => q{unbekannt},
            'en' => q{unknown},
        },
        'at' => {
            'de' => q{um},
            'en' => q{at},
        }
    },
    'chart_html_bar' => {
        'title' => {
            'de' => q{Niederschlagsdiagramm},
            'en' => q{Precipitation chart}
        },
        'data_start' => {
            'de' => q{Datenbeginn},
            'en' => q{Data start},
        }
    },
    'chart_gchart' => {
        'legend_time_axis' => {
            'de' => 'Uhrzeit',
            'en' => 'Time',
        },
        'legend_volume_axis' => {
            'de' => 'mm/h',
            'en' => 'mm/h',
        },
        'title' => {
            'de' => 'Niederschlagsvorhersage für %s, %s',
            'en' => 'Precipitation forecast for %s, %s',
        },
        'legend' => {
            'de' => 'Niederschlag',
            'en' => 'Precipitation',
        },
    },
    'handle_attributes' => {
        'interval' => {
            'de' =>
                'ist kein valider Wert für den Intervall. Einzig 10, 60, 120, 180, 240 oder 300 sind erlaubt!',
            'en' =>
                'is no valid value for interval. Only 10, 60, 120, 180, 240 or 300 are allowed!',
        },
        'region' => {
            'de' =>
                q{ist kein valider Wert für die Region. Einzig 'de' oder 'nl' werden unterstützt!},
            'en' =>
                q{is no valid value for region. Only 'de' or 'nl' are allowed!},
        },
        'default_chart' => {
            'de' =>
                q{ist kein valider Wert für den Standard-Graphen. Valide Werte sind none, GChart,TextChart oder HTMLChart},
            'en' =>
                q{is not a valid value for the default chart. Valid values are none, GChart,TextChart or HTMLChart},
        },
    },
);

############################################################    Global variables
my @errors;
my $global_hash;

GPUtils::GP_Export(
    qw(
        Initialize
    )
);

############################################################    FHEM API related
#   JFTR:
#       ATM the FHEM API does need an Initialize() subroutine, so this is mandatory
#
## no critic (NamingConventions::Capitalization)
sub Initialize {

    my $hash = shift;

    $hash->{DefFn}       = \&FHEM::Buienradar::handle_define;
    $hash->{UndefFn}     = \&FHEM::Buienradar::handle_undefine;
    $hash->{GetFn}       = \&FHEM::Buienradar::handle_get;
    $hash->{SetFn}       = \&FHEM::Buienradar::handle_set;
    $hash->{AttrFn}      = \&FHEM::Buienradar::handle_attributes;
    $hash->{FW_detailFn} = \&FHEM::Buienradar::handle_fhemweb_details;
    $hash->{AttrList}    = join(
        q{ },
        (
            'disabled:on,off',
            'region:nl,de',
            'interval:10,60,120,180,240,300',
            'default_chart:none,HTMLChart,GChart,TextChart'
        )
    ) . qq[ $::readingFnAttributes ];
    $hash->{REGION} = $DEFAULT_REGION;

    return FHEM::Meta::InitMod( __FILE__, $hash );
}
## use critic

sub handle_fhemweb_details {
    my $fhemweb_name    = shift;
    my $name            = shift;
    my $room            = shift;
    my $page_definition = shift;
    my $hash            = get_device_definition($name);

    return if ( !defined( $hash->{URL} ) );

    # @todo error in the second return: missing target attribute
    # @todo I18N
    if ( ::ReadingsVal( $name, 'rainData', 'unknown' ) ne q{unknown} ) {
        for ( ::AttrVal( $name, q{default_chart}, q{none} ) ) {
            when (q{HTMLChart}) { return chart_html_bar($name) }
            when (q{GChart})    { return chart_gchart($name) }
            when (q{TextChart}) {
                return q[<pre>] . chart_textbar( $name, q{#} ) . q[</pre>]
            }
            default { return q{} }
        }
    }

    return;
}

sub handle_define {

    my $hash = shift;
    my $def  = shift;
    $global_hash = $hash;

    if ( !FHEM::Meta::SetInternals($hash) ) {
        return $EVAL_ERROR;
    }

    my @arguments        = split m{ \s+ }xms, $def;
    my $name             = $arguments[0];
    my $arguments_length = scalar @arguments;
    my $latitude;
    my $longitude;
    my $language = get_global_language();

    Readonly my $ARGUMENT_LENGTH_WITHOUT_LOC => 2;
    Readonly my $ARGUMENT_LENGHT_WITH_LOC    => 4;
    Readonly my $ARGUMENT_POSITION_LATITUDE  => 2;
    Readonly my $ARGUMENT_POSITION_LONGITUDE => 3;

    # todo: Refactor to for()
    if ( $arguments_length == $ARGUMENT_LENGTH_WITHOUT_LOC ) {
        $latitude  = ::AttrVal( 'global', 'latitude',  $DEFAULT_LATITUDE );
        $longitude = ::AttrVal( 'global', 'longitude', $DEFAULT_LONGITUDE );
    }
    elsif ( $arguments_length == $ARGUMENT_LENGHT_WITH_LOC ) {
        $latitude  = $arguments[$ARGUMENT_POSITION_LATITUDE];
        $longitude = $arguments[$ARGUMENT_POSITION_LONGITUDE];
    }
    else {
        return handle_error( $name,
            q{Syntax: define <name> Buienradar [<latitude> <longitude>]} );
    }

    ::readingsSingleUpdate( $hash, 'state', 'Initialized', 1 );

    $hash->{NAME}      = $name;
    $hash->{VERSION}   = $VERSION;
    $hash->{INTERVAL}  = $DEFAULT_INTERVAL;
    $hash->{LATITUDE}  = $latitude;
    $hash->{LONGITUDE} = $longitude;
    $hash->{URL}       = undef;

    # get language for language dependend legend

    ::readingsBeginUpdate($hash);
    ::readingsBulkUpdate( $hash, 'rainNow',       'unknown' );
    ::readingsBulkUpdate( $hash, 'rainDataStart', 'unknown' );
    ::readingsBulkUpdate( $hash, 'rainBegin',     'unknown' );
    ::readingsBulkUpdate( $hash, 'rainEnd',       'unknown' );
    ::readingsEndUpdate( $hash, 1 );

    # set default region nl
    if ( !::AttrVal( $name, 'region', undef ) ) {
        ::CommandAttr( undef, qq[$name region nl] );
    }

    if ( !::AttrVal( $name, 'interval', undef ) ) {
        ::CommandAttr( undef,
            qq[$name interval $FHEM::Buienradar::DEFAULT_INTERVAL] );
    }

    update_timer($hash);

    return;
}

sub handle_undefine {
    my $hash = shift;
    my $arg  = shift;
    ::RemoveInternalTimer( $hash, \&FHEM::Buienradar::update_timer );
    return;
}

sub handle_set {
    my $hash = shift;
    my $name = shift;
    my $opt  = shift;
    my @args = shift;

    if ( !defined $opt ) {
        return return qq{'set $name' needs at least one argument};
    }

    for ($opt) {
        when (q{refresh}) {
            request_data_update($hash);
            return q{};
        }

        default {
            return qq{Unknown argument $opt, choose one of refresh:noArg'};
        }
    }

    return qq{Unknown argument $opt, choose one of refresh:noArg};
}

sub handle_get {

    my $hash = shift;
    my $name = shift;
    my $opt  = shift;
    my @args = shift;

    if ( !defined $opt ) {
        return qq['get $name' needs at least one argument];
    }

    for ($opt) {
        when ('version') {
            return $VERSION;
        }

        # @todo I18N
        when ('startsIn') {
            my $begin = $hash->{'.RainStart'};

            if ( !$begin ) {
                return q[No data available];
            }

            return q[It is raining] if $begin == 0;

            my $time_diff_in_seconds = $begin - time;
            return scalar timediff2str($time_diff_in_seconds);
        }

        when ('rainDuration') {
            return ::ReadingsVal( $name, 'rainDuration', 'unknown' );
        }

        default {
            return
                qq[Unknown argument $opt, choose one of version:noArg startsIn:noArg rainDuration:noArg];
        }
    }
    return;
}

sub handle_attributes {
    my $command         = shift;
    my $name            = shift;
    my $attribute_name  = shift;
    my $attribute_value = shift;
    my $hash            = get_device_definition($name);
    my $language        = get_global_language();

    debug_message(
        $name,
        Dumper(
            {
                command   => $command,
                device    => $name,
                attribute => $attribute_name,
                value     => $attribute_value
            }
        )
    );

    for ($attribute_name) {

        # JFTR: disabled will also set disable to be compatible to FHEM::IsDisabled()
        #       This is a ugly hack, with some side-effects like you can set disabled, disable will be automatically
        #       set, you can delete disable but disabled will still be set.
        when ('disabled') {
            for ($command) {
                when ('set') {

                    # todo: this is double checked
                    return
                        qq[${attribute_value} is not a valid value for disabled. Only 'on' or 'off' are allowed!]
                        if ( List::Util::any { $_ eq $attribute_value }
                            qw{ on off 0 1 } );

                    if ( List::Util::any { $_ eq $attribute_value } qw{ on 1 } )
                    {
                        ::RemoveInternalTimer( $hash,
                            \&FHEM::Buienradar::update_timer );
                        disable_device($name);
                        $hash->{NEXTUPDATE} = undef;
                        $hash->{STATE}      = 'inactive';
                        return;
                    }

                    if ( List::Util::any { $_ eq $attribute_value }
                        qw{ off 0 } )
                    {
                        enable_device($name);
                        update_timer($hash);
                        return;
                    }
                }

                when ('del') {
                    enable_device($name);
                    update_timer($hash);
                }
            }
        }

        when ('region') {
            return handle_error( $name,
                qq[${attribute_value} ${FHEM::Buienradar::TRANSLATIONS{'handle_attributes'}{'region'}{$language}}]
            )
                if ( $command eq q{set}
                    && !List::Util::any { $_ eq $attribute_value } qw{ de nl } );

            for ($command) {
                when ('set') {
                    $hash->{REGION} = $attribute_value;
                }

                when ('del') {
                    $hash->{REGION} = 'nl';
                }
            }

            request_data_update($hash);
            return;
        }

        when ('interval') {
            return handle_error( $name,
                qq[${attribute_value} ${FHEM::Buienradar::TRANSLATIONS{'handle_attributes'}{'interval'}{$language}}]
            )
                if ( $command eq q{set}
                    && !List::Util::any { $_ eq $attribute_value }
                    qw{ 10 60 120 180 240 300 } );

            for ($command) {
                when ('set') {
                    $hash->{INTERVAL} = $attribute_value;
                }

                when ('del') {
                    $hash->{INTERVAL} = $DEFAULT_INTERVAL;
                }
            }

            update_timer($hash);
            return;
        }

        when (q{default_chart}) {
            for ($command) {
                when (q{set}) {
                    return handle_error( $name,
                        qq[${attribute_value} ${FHEM::Buienradar::TRANSLATIONS{'handle_attributes'}{'default_chart'}{$language}}]
                    )
                        if ( !List::Util::any { $_ eq $attribute_value }
                            qw{ none HTMLChart GChart TextChart } );
                }
                when (q{del}) {
                    return;
                }
            }
        }

    }

    return;
}

############################################################    helper subroutines
sub timediff2str {
    my $s = shift // return;

    if ( !defined wantarray ) {
        return;
    }

    Readonly my $SECONDS_IN_MINUTE => 60;
    Readonly my $MINUTES_IN_HOUR   => 60;
    Readonly my $HOURS_IN_DAY      => 24;

    return (
        wantarray
            ? ( 0, 0, 0, $s )
            : sprintf '%02d Sekunden', $s
    ) if $s < $SECONDS_IN_MINUTE;

    my $m = $s / $SECONDS_IN_MINUTE;
    $s = $s % $SECONDS_IN_MINUTE;

    return (
        wantarray
            ? ( 0, 0, POSIX::floor($m), POSIX::floor($s) )
            : sprintf '%02d Minuten, %02d Sekunden',
            $m, $s
    ) if $m < $MINUTES_IN_HOUR;

    my $h = $m / $MINUTES_IN_HOUR;
    $m %= $MINUTES_IN_HOUR;

    return (
        wantarray
            ? ( 0, POSIX::floor($h), POSIX::floor($m), POSIX::floor($s) )
            : sprintf '%02d Stunden, %02d Minuten, %02d Sekunden',
            $h, $m, $s )
        if $h < $HOURS_IN_DAY;

    my $d = $h / $HOURS_IN_DAY;
    $h %= $HOURS_IN_DAY;
    return (
        wantarray
            ? (
            POSIX::floor($d), POSIX::floor($h),
            POSIX::floor($m), POSIX::floor($s)
        )
            : sprintf '%d Tage, %02d Stunden, %02d Minuten, %02d Sekunden',
            $d, $h, $m, $s
    );
}

## no critic (ProhibitPackageVars)

=for todo
Accesses $::defs. This is just a kludge for the non-existen FHEM API to access device details
Should be fixed if possible!
=cut

sub get_device_definition {

    my $name = shift;
    return $::defs{$name};
}

=for todo

Accesses $::defs{$device}{disable}. This is just a kludge for the non-existent FHEM API
to access device details. Should be fixed if possible!

=cut

sub disable_device {
    my $name = shift;
    $::attr{$name}{'disable'} = 1;
    return;
}

=for todo

Accesses $::defs{$device}{disable}. This is just a kludge for the non-existen FHEM API to access device details
Should be fixed if possible!

=cut

sub enable_device {
    my $name = shift;
    $::attr{$name}{'disable'} = 0;
    return;
}
## use critic

sub get_global_language {
    return lc ::AttrVal( q{global}, 'language', $DEFAULT_LANGUAGE );
}

sub debug_message {
    local $OFS = qq{\n};
    my $device_name = shift;
    if ( int( ::AttrVal( q{global}, q{verbose}, 0 ) ) >= $DEBUGGING_MIN_VERBOSE
        or int( ::AttrVal( $device_name, q{debug}, 0 ) ) == 1 )
    {
        ::Debug( join $OFS, ( qq{[$device_name]}, qq{@_} ) );
    }

    return;
}

sub handle_error {
    my $device_name = shift;
    my $message     = shift || q{Something bad happened. Unknown error!};
    return qq{[$device_name] Error: $message};
}

############################################################    Request handling

sub update_timer {
    my ($hash) = shift;
    my $nextupdate = 0;

    ::RemoveInternalTimer( $hash, \&FHEM::Buienradar::update_timer );

    $nextupdate = int( time() + $hash->{INTERVAL} );
    $hash->{NEXTUPDATE} = ::FmtDateTime($nextupdate);
    request_data_update($hash);

    ::InternalTimer( $nextupdate, \&FHEM::Buienradar::update_timer, $hash );

    return 1;
}

sub parse_http_response {
    my $param = shift;
    my $err   = shift;
    my $data  = shift;
    my $hash  = $param->{hash};
    my $name  = $hash->{NAME};
    $hash->{'.RainStart'} = undef;

    Readonly my $INTERVAL_LENGTH_MINUTES    => 5;
    Readonly my $INTERVAL_LENGHT_SECONDS    => $INTERVAL_LENGTH_MINUTES * ONE_MINUTE;
    # todo: secondary usage!
    Readonly my $MINUTES_IN_HOUR            => 60;
    Readonly my $TOTAL_PERCENTAGE           => 100;
    Readonly my $LAMETRIC_MULTIPILIER       => 1000;
    Readonly my $LAMETRIC_MAX_VALUES        => 12;

    my %precipitation_forecast;

    if ( $err ne q{} ) {
        ::readingsSingleUpdate( $hash, 'state', qq[Error: $err =>$data], 1 );
        reset_request_result($hash);
    }
    elsif ( $data ne q{} ) {
        my $forecast_data;
        my $error;

        if ( defined $param->{'code'} && $param->{'code'} ne '200' ) {
            $error = sprintf
                'Pulling %s returns HTTP status code %d instead of 200.',
                $hash->{URL},
                $param->{'code'};

            debug_message( $name, qq[HTTP Response code is: $param->{'code'}] );

            if ( $param->{'code'} eq '404' ) {
                my $response_body;

                if ( !@errors ) {
                    $response_body = eval { $response_body = from_json($data) };
                }

                if ($EVAL_ERROR) {
                    debug_message( $name, q{Response body},
                        Dumper($response_body) );
                    $error =
                        qq[Location is not in coverage for region '$hash->{REGION}'];
                }
            }

            handle_error( $name, qq{$error} );
            debug_message( $name, Dumper($param) );
            ::readingsSingleUpdate( $hash, 'state', $error, 1 );
            reset_request_result($hash);
            return;
        }

        if ( !@errors ) {
            $forecast_data = eval { $forecast_data = from_json($data) };
        }

        if ($EVAL_ERROR) {
            $error = qq{Can't evaluate JSON from $hash->{URL}: $EVAL_ERROR};
            handle_error( $name, qq{$error} );
            debug_message( $name, join q{},
                map { qq{[$name] $_} } Dumper($data) );
            ::readingsSingleUpdate( $hash, q{state}, $error, 1 );
            reset_request_result($hash);
            return;
        }

        if ( !$forecast_data->{'success'} ) {
            $error =
                q{Got JSON from buienradar.nl, but had some troubles delivering meaningful data!};
            handle_error( $name, qq{$error} );
            debug_message( $name, join q{},
                map { qq{[$name] $_} } Dumper($data) );
            ::readingsSingleUpdate( $hash, 'state', $error, 1 );
            reset_request_result($hash);
            return;
        }

        my @precip;

        if ( !@errors ) {
            @precip = @{ $forecast_data->{'precip'} };
        }

        debug_message( $name,
            q{Received data: } . Dumper( @{ $forecast_data->{'precip'} } ) );

        if ( scalar @precip > 0 ) {
            my $data_lametric = join q{,}, map { $_ * $LAMETRIC_MULTIPILIER } @precip[ 0 .. $LAMETRIC_MAX_VALUES-1 ];
            my $rain_total    = List::Util::sum @precip;
            my $rain_max      = List::Util::max @precip;
            my $rain_start    = undef;
            my $rain_end      = undef;
            my $data_start    = $forecast_data->{start};
            my $data_end = $data_start + ( scalar @precip ) * $INTERVAL_LENGHT_SECONDS;
            my $forecast_start      = $data_start;
            my $rain_now            = undef;
            my $rain_data           = join q{:}, @precip;
            my $rain_amount         = $precip[0];
            my $is_raining          = undef;
            my $intervals_with_rain = scalar map { $_ > 0 ? $_ : () } @precip;
            $hash->{'.RainStart'} = q{unknown};
            my $precip_length = scalar @precip;

            for my $precip_index ( 0 .. $precip_length ) {

                my $start  = $forecast_start + $precip_index * $INTERVAL_LENGHT_SECONDS;
                my $end    = $start +  $INTERVAL_LENGHT_SECONDS;
                my $precip = $precip[$precip_index];
                $is_raining = undef;    # reset

                # set a flag if it's raining
                if ( $precip > 0 ) {
                    $is_raining = 1;
                }

                # there is precipitation and start is not yet set
                if ( not $rain_start and $is_raining ) {
                    $rain_start = $start;
                    $hash->{'.RainStart'} = $rain_start;
                }

                # It's raining again, so we have to reset rainEnd for a new chance
                if ( $is_raining and $rain_end ) {
                    $rain_end = undef;
                }

                # It's not longer raining, so set rainEnd (again)
                if ( $rain_start and not $is_raining and not $rain_end ) {
                    $rain_end = $start;
                }

                if ( time() ~~ [ $start .. $end ] ) {
                    $rain_now = $precip;
                    $hash->{'.RainStart'} = 0;
                }

                $precipitation_forecast{$start} = {
                    'start'         => $start,
                    'end'           => $end,
                    'precipitation' => $precip,
                };
            }

            debug_message( $name, Dumper(%precipitation_forecast) );

            $hash->{'.SERIALIZED'} =
                Storable::freeze( \%precipitation_forecast );

            ::readingsBeginUpdate($hash);
            ::readingsBulkUpdate(
                $hash, 'state',
                $rain_now
                    ? sprintf '%.3f',
                    $rain_now
                    : 'unknown'
            );
            ::readingsBulkUpdate( $hash, 'rainTotal', sprintf '%.3f',
                $rain_total );
            ::readingsBulkUpdate( $hash, 'rainAmount', sprintf '%.3f',
                $rain_amount );
            ::readingsBulkUpdate(
                $hash, 'rainNow',
                $rain_now
                    ? sprintf '%.3f',
                    $rain_now
                    : 'unknown'
            );
            ::readingsBulkUpdate( $hash, 'rainLaMetric', $data_lametric );
            ::readingsBulkUpdate(
                $hash, 'rainDataStart',
                POSIX::strftime '%R',
                    localtime $data_start
            );
            ::readingsBulkUpdate(
                $hash, 'rainDataEnd',
                POSIX::strftime '%R',
                    localtime $data_end
            );
            ::readingsBulkUpdate( $hash, 'rainMax', sprintf '%.3f', $rain_max );
            ::readingsBulkUpdate(
                $hash,
                'rainBegin',
                (
                    ($rain_start)
                        ? POSIX::strftime '%R',
                        localtime $rain_start
                        : 'unknown'
                )
            );
            ::readingsBulkUpdate(
                $hash,
                'rainEnd',
                (
                    ($rain_end)
                        ? POSIX::strftime '%R',
                        localtime $rain_end
                        : 'unknown'
                )
            );
            ::readingsBulkUpdate( $hash, 'rainData', $rain_data );
            ::readingsBulkUpdate( $hash, 'rainDuration',
                $intervals_with_rain * $INTERVAL_LENGTH_MINUTES );
            ::readingsBulkUpdate( $hash, 'rainDurationIntervals',
                $intervals_with_rain );
            ::readingsBulkUpdate( $hash, 'rainDurationPercent',
                ( $intervals_with_rain / scalar @precip ) * $TOTAL_PERCENTAGE );
            ::readingsBulkUpdate(
                $hash,
                'rainDurationTime',
                sprintf '%02d:%02d',
                    (
                        ( $intervals_with_rain * $INTERVAL_LENGTH_MINUTES / $MINUTES_IN_HOUR ),
                        $intervals_with_rain * $INTERVAL_LENGTH_MINUTES % $MINUTES_IN_HOUR
                    )
            );
            ::readingsEndUpdate( $hash, 1 );
        }
    }

    return;
}

sub reset_request_result {
    my $hash = shift;

    $hash->{'.SERIALIZED'} = undef;

    ::readingsBeginUpdate($hash);
    ::readingsBulkUpdate( $hash, 'rainTotal',     'unknown' );
    ::readingsBulkUpdate( $hash, 'rainAmount',    'unknown' );
    ::readingsBulkUpdate( $hash, 'rainNow',       'unknown' );
    ::readingsBulkUpdate( $hash, 'rainLaMetric',  'unknown' );
    ::readingsBulkUpdate( $hash, 'rainDataStart', 'unknown' );
    ::readingsBulkUpdate( $hash, 'rainDataEnd',   'unknown' );
    ::readingsBulkUpdate( $hash, 'rainMax',       'unknown' );
    ::readingsBulkUpdate( $hash, 'rainBegin',     'unknown' );
    ::readingsBulkUpdate( $hash, 'rainEnd',       'unknown' );
    ::readingsBulkUpdate( $hash, 'rainData',      'unknown' );
    ::readingsEndUpdate( $hash, 1 );

    return;
}

sub request_data_update {
    my ($hash) = shift;
    my $region = $hash->{REGION};
    my $name   = $hash->{NAME};

    # @todo candidate for refactoring to sprintf
    $hash->{URL} =
        ::AttrVal( $name, 'BaseUrl',
            'https://cdn-secure.buienalarm.nl/api/3.4/forecast.php' )
            . '?lat='
            . $hash->{LATITUDE} . '&lon='
            . $hash->{LONGITUDE}
            . '&region='
            . $region
            . '&unit=' . 'mm/u';

    my $param = {
        url      => $hash->{URL},
        timeout  => 10,
        hash     => $hash,
        method   => 'GET',
        callback => \&parse_http_response
    };

    ::HttpUtils_NonblockingGet($param);
    debug_message( $name, q{Data update requested} );

    return;
}

############################################################    Charts

sub chart_html_bar {
    my $name     = shift;
    my $width    = shift;
    my $hash     = get_device_definition($name);
    my @values   = split /:/xms, ::ReadingsVal( $name, 'rainData', '0:0' );
    my $language = get_global_language();

    Readonly my $HTML_MAX_SIZE_PX => 700;

    my $as_html = <<'CSS_STYLE';
<style>

.buienradar .htmlchart div {
  font: 10px sans-serif;
  background-color: steelblue;
  text-align: right;
  padding: 3px;
  margin: 1px;
  color: white;
}

</style>
<div class='buienradar'>
CSS_STYLE

    $as_html .= qq[<p><a href="./fhem?detail=$name">$name</a>];
    $as_html .= sprintf
        q{<p>%s %s %s</p>},
        $TRANSLATIONS{'chart_html_bar'}{'data_start'}{$language},
        $TRANSLATIONS{'general'}{'at'}{$language},
        ::ReadingsVal( $name, 'rainDataStart',
            $TRANSLATIONS{'general'}{'unknown'}{$language} );
    my $factor =
        ( $width ? $width : $HTML_MAX_SIZE_PX ) /
            ( 1 + ::ReadingsVal( $name, 'rainMax', q{0} ) );

    $as_html .= q[<div class='htmlchart'>];
    foreach my $bar_value (@values) {
        $as_html .= sprintf
            q{<div style='width: %dpx'>%.3f</div>},
            ( int( $bar_value * $factor ) + 30 ),
            $bar_value;
    }

    $as_html .= q[</div>];
    return ($as_html);
}

sub chart_gchart {
    my $name     = shift;
    my $hash     = get_device_definition($name);
    my $language = get_global_language();

    if ( !$hash->{'.SERIALIZED'} ) {
        handle_error( $name,
            q{Can't return serizalized data for FHEM::Buienradar::chart_gchart.}
        );

        # return dummy data
        return;
    }

    # read & parse stored data
    my %stored_data = %{ Storable::thaw( $hash->{'.SERIALIZED'} ) };
    my $data        = join ', ', map {
        chart_gchart_get_dataset( $stored_data{$_}{'start'},
            $stored_data{$_}{'precipitation'} );
    } sort keys %stored_data;

    # create data for the GChart
    my $legend_time_axis =
        $TRANSLATIONS{'chart_gchart'}{'legend_time_axis'}{$language};
    my $legend_volume_axis =
        $TRANSLATIONS{'chart_gchart'}{'legend_volume_axis'}{$language};
    my $title = sprintf
        $TRANSLATIONS{'chart_gchart'}{'title'}{$language},
        $hash->{LATITUDE},
        $hash->{LONGITUDE};
    my $legend = $TRANSLATIONS{'chart_gchart'}{'legend'}{$language};
    debug_message( $name, qq{Legend langauge is: $language} );
    debug_message( $name, qq{Legend is: $legend} );

    return <<"CHART";
<div id='chart_${name}'; style='width:100%; height:100%'></div>
<script type='text/javascript' src='https://www.gstatic.com/charts/loader.js'></script>
<script type='text/javascript'>

    google.charts.load('current', {packages:['corechart']});
    google.charts.setOnLoadCallback(drawChart);
    function drawChart() {
        var data = google.visualization.arrayToDataTable([
            ['string', '${legend}'],
            ${data}
        ]);

        var options = {
            title: '${title}',
            hAxis: {
                title: '${legend_time_axis}',
                slantedText:true,
                slantedTextAngle: 45,
                textStyle: {
                    fontSize: 10}
            },
            vAxis: {
                minValue: 0,
                title: '${legend_volume_axis}'
            }
        };

        var my_div = document.getElementById(
            'chart_${name}');        var chart = new google.visualization.AreaChart(my_div);
        google.visualization.events.addListener(chart, 'ready', function () {
            my_div.innerHTML = '<img src=' + chart.getImageURI() + '>';
        });

        chart.draw(data, options);}
</script>

CHART
}

sub chart_gchart_get_dataset {
    my $start         = shift;
    my $precipitation = shift;

    my ( $k, $v ) = (
        POSIX::strftime( '%H:%M', localtime $start ),
        sprintf '%.3f', $precipitation,
    );

    return qq{['$k', $v]};
}

sub logproxy_wrapper {
    my $name = shift;
    my $hash = get_device_definition($name);

    if ( !$hash->{'.SERIALIZED'} ) {
        handle_error( $name,
            q{Can't return serizalized data for FHEM::Buienradar::logproxy_wrapper. Using dummy data}
        );

        # return dummy data
        return ( 0, 0, 0 );
    }

    my %data = %{ Storable::thaw( $hash->{'.SERIALIZED'} ) };

    return (
        join qq{\n},
            map {
                join q{ },
                    (
                        POSIX::strftime( '%F_%T', localtime $data{$_}{'start'} ),
                        sprintf '%.3f',
                            $data{$_}{'precipitation'}
                    )
            } keys %data,
                0,
                ::ReadingsVal( $name, 'rainMax', 0 )
    );
}

sub chart_textbar {
    my $name          = shift;
    my $bar_character = shift || $DEFAULT_TEXT_BAR_CHAR;
    my $hash          = get_device_definition($name);

    if ( !$hash->{'.SERIALIZED'} ) {
        handle_error( $name,
            q{Can't return serizalized data for FHEM::Buienradar::TextChart.} );

        # return dummy data
        return;
    }

    my %stored_data = %{ Storable::thaw( $hash->{'.SERIALIZED'} ) };

    my $data = join qq{\n}, map {
        join ' | ',
            chart_text_show_bar( $hash->{q{.SERIALIZED}}, $bar_character );
    } sort keys %stored_data;

    return $data;
}

sub chart_text_show_bar {
    my $data          = shift;
    my $bar_character = shift;
    my %stored_data   = %{ Storable::thaw($data) };

    my ( $time, $precip, $bar ) = (
        POSIX::strftime( '%H:%M', localtime $stored_data{$_}{'start'} ),
        sprintf( '% 7.3f', $stored_data{$_}{'precipitation'} ),
        (
            ( $stored_data{$_}{'precipitation'} < 50 )
                ? $bar_character x
                POSIX::lround( abs $stored_data{$_}{'precipitation'} * 10 )
                : ( $bar_character x 50 ) . q{>}
        ),
    );

    return ( $time, $precip, $bar );
}

1;

__END__

=pod

=encoding utf8

=head1 NAME

    FHEM::Buienradar - Support for Buienradar.nl precipitation data

=head1 VERSION

    3.0.8

=head1 SYNOPSIS

    See POD section below

=head1 DESCRIPTION

    See POD section below

=head1 SUBROUTINES/METHODS

=over 1

=item timediff2str($seconds)

Create a human readable representation for a given time t, like x minutes, y seconds, but only
with the necessary pieces.

Respects your wishes regarding scalar / list context, e.g.

=over 2

=item Parameters

=over 3

=item *  C<$seconds> - time to handle in seconds

=back

=item Return values

=over 3

=item * If called in list context: a list containing four elements

    # list context
    say Dumper(timediff2str(10000))
    > $VAR1 = '1';
    > $VAR2 = '3';
    > $VAR3 = '46';
    > $VAR4 = '40';

=item * If called in scalar context: a formatted string

    say Dumper(scalar timediff2str(100000));
    > $VAR1 = '1 Tage, 03 Stunden, 46 Minuten, 40 Sekunden';

=back

=back

=item chart_textbar($device_name)

Returns the precipitation data as textual chart representation

=over 2

=item Parameters

=over 3

=item * C<$device_name> - name of the Buienradar device, getting the data from

=back

=item Return values

=over 3

=item * Text chart as a plain text string

=begin text

    8:25  |   0.000 |
    18:30 |   0.000 |
    18:35 |   0.000 |
    18:40 |   0.000 |
    18:45 |   0.000 |
    18:50 |   0.000 |
    18:55 |   0.000 |
    19:00 |   0.000 |
    19:05 |   0.000 |
    19:10 |   0.000 |
    19:15 |   0.060 | #
    19:20 |   0.370 | ####
    19:25 |   0.650 | #######
    19:30 |   0.490 | #####
    19:35 |   0.220 | ##
    19:40 |   0.110 | #
    19:45 |   0.290 | ###
    19:50 |   0.560 | ######
    19:55 |   0.700 | #######
    20:00 |   0.320 | ###
    20:05 |   0.560 | ######
    20:10 |   0.870 | #########
    20:15 |   0.810 | ########
    20:20 |   1.910 | ###################
    20:25 |   1.070 | ###########

=end text

=back

=back

=item chart_html_bar($device_name, $max_width)

Get precipitation data as HTML bar chart

=over 2

=item Parameters

=over 3

=item * C<$device_name> - name of the Buienradar device, getting the data from

=item * C<$width> - Maximum width in px for the HTML bars

=back

=item Return values

=over 3

=item * Chart as HTML as single string

=back

=back

=item chart_gchart($device_name)

Get precipitation data as Google Chart

=over 2

=item Parameters

=over 3

=item * C<$device_name> - name of the Buienradar device, getting the data from

=back

=item Return values

Log look-alike data, like

=over 3

=item   * The generated HTML source code

=back

=back

=item logproxy_wrapper($device_name)

Returns FHEM log look-alike data from the current data for using it with
FTUI.

=over 2

=item Parameters

=over 3

=item * C<$device_name> - name of the Buienradar device, getting the data from

=back

=item Return values

=over 3

=item   * LogProxy compatible data

=begin text

2019-08-05_14:40:00 0.000
2019-08-05_13:45:00 0.000
2019-08-05_14:25:00 0.000
2019-08-05_15:15:00 0.000
2019-08-05_14:55:00 0.000
2019-08-05_15:30:00 0.000
2019-08-05_14:45:00 0.000
2019-08-05_15:25:00 0.000
2019-08-05_13:30:00 0.000
2019-08-05_13:50:00 0.000

=end text

=item   * Fixed value of 0

=item   * Maximal amount of rain in a 5 minute interval

=back

=back

=back

=head1 DIAGNOSTICS

=head1 AUTHOR

    Christoph Morrison, <fhem@christoph-jeschke.de>
    <https://github.com/christoph-morrison>

=head1 CONTRIBUTORS

    lubeda <https://github.com/lubeda>

=head1 DEPENDENCIES

=over 1

=item * Perl 5.13.9

=item * Readonly <https://metacpan.org/pod/Readonly>

=item * JSON::MaybeXS <https://metacpan.org/pod/JSON::MaybeXS>

=back

=head1 INCOMPATIBILITIES

=head1 CONFIGURATION AND ENVIRONMENT

=head1 BUGS AND LIMITATIONS

    Please report bugs here: <https://github.com/fhem/mod-Buienradar/issues>

=head1 LICENSE AND COPYRIGHT

    SPDX Identifier: Unlicense

    This is free and unencumbered software released into the public domain.

    Anyone is free to copy, modify, publish, use, compile, sell, or
    distribute this software, either in source code form or as a compiled
    binary, for any purpose, commercial or non-commercial, and by any
    means.

    In jurisdictions that recognize copyright laws, the author or authors
    of this software dedicate any and all copyright interest in the
    software to the public domain. We make this dedication for the benefit
    of the public at large and to the detriment of our heirs and
    successors. We intend this dedication to be an overt act of
    relinquishment in perpetuity of all present and future rights to this
    software under copyright law.

    THE SOFTWARE IS PROVIDED 'AS IS', WITHOUT WARRANTY OF ANY KIND,
    EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
    MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.
    IN NO EVENT SHALL THE AUTHORS BE LIABLE FOR ANY CLAIM, DAMAGES OR
    OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE,
    ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR
    OTHER DEALINGS IN THE SOFTWARE.

    For more information, please refer to <http://unlicense.org/>

    See also https://www.buienradar.nl/overbuienradar/gratis-weerdata

=over 1

=item helper

=item summary Precipitation forecasts based on buienradar.nl

=item summary_DE Niederschlagsvorhersage auf Basis des Wetterdienstes buienradar.nl

=back

=begin html

<p><a name="Buienradar" id="Buienradar"></a></p>
<h2>Buienradar</h2>
<p>Buienradar provides access to precipitation forecasts by the dutch service <a href="https://www.buienradar.nl">Buienradar.nl</a>.</p>
<p><span id="Buienradardefine"></span></p>
<h3>Define</h3>
<pre><code>define &lt;devicename&gt; Buienradar [latitude] [longitude]</code></pre>
<p><var>latitude</var> and <var>longitude</var> are facultative and will gathered from <var>global</var> if not set. So the smallest possible definition is:</p>
<pre><code>define &lt;devicename&gt; Buienradar</code></pre>
<p><span id="Buienradarset"></span></p>
<h3>Set</h3>
<p><var>Set</var> will get you the following:</p>
<ul>
  <li><code>refresh</code> - get new data from Buienradar.nl.</li>
</ul>
<p><span id="Buienradarget"></span></p>
<h3>Get</h3>
<p><var>Get</var> will get you the following:</p>
<ul>
  <li><code>rainDuration</code> - predicted duration of the next precipitation in minutes.</li>
  <li><code>startsIn</code> - next precipitation starts in <var>n</var> minutes. <strong>Obsolete!</strong></li>
  <li><code>version</code> - get current version of the Buienradar module.</li>
</ul>
<p><span id="Buienradarreadings"></span></p>
<h3>Readings</h3>
<p>Buienradar provides several readings:</p>
<ul>
  <li>
    <p><code>rainAmount</code> - amount of predicted precipitation in mm/h for the next 5 minute interval.</p>
  </li>
  <li>
    <p><code>rainBegin</code> - starting time of the next precipitation, <var>unknown</var> if no precipitation is predicted.</p>
  </li>
  <li>
    <p><code>raindEnd</code> - ending time of the next precipitation, <var>unknown</var> if no precipitation is predicted.</p>
  </li>
  <li>
    <p><code>rainDataStart</code> - starting time of gathered data.</p>
  </li>
  <li>
    <p><code>rainDataEnd</code> - ending time of gathered data.</p>
  </li>
  <li>
    <p><code>rainLaMetric</code> - data formatted for a LaMetric device.</p>
  </li>
  <li>
    <p><code>rainMax</code> - maximal amount of precipitation for <strong>any</strong> 5 minute interval of the gathered data in mm/h.</p>
  </li>
  <li>
    <p><code>rainNow</code> - amount of precipitation for the <strong>current</strong> 5 minute interval in mm/h.</p>
  </li>
  <li>
    <p><code>rainTotal</code> - total amount of precipition for the gathered data in mm/h.</p>
  </li>
  <li>
    <p><code>rainDuration</code> - duration of the precipitation contained in the forecast</p>
  </li>
  <li>
    <p><code>rainDurationTime</code> - duration of the precipitation contained in the forecast in HH:MM</p>
  </li>
  <li>
    <p><code>rainDurationIntervals</code> - amount of intervals with precipitation</p>
  </li>
  <li>
    <p><code>rainDurationPercent</code> - percentage of interavls with precipitation</p>
  </li>
</ul>
<p><span id="Buienradarattr"></span></p>
<h3>Attributes</h3>
<ul>
  <li>
    <p><a name="disabled" id="disabled"></a> <code>disabled on|off</code> - If <code>disabled</code> is set to <code>on</code>, no further requests to Buienradar.nl will be performed. <code>off</code> reactivates the device, also if the attribute ist simply deleted.</p>
    <p><strong>Caution!</strong> To be compatible with <code>FHEM::IsDisabled()</code>, any set or delete with <code>disabled</code> will also create or delete an additional <code>disable</code> attribute. Is <code>disable</code> (without d) set or deleted, <code>disabled</code> (with d) will not be affected. <em>Just don't use <code>disable</code></em>.</p>
  </li>
  <li>
    <p><a name="region" id="region"></a> <code>region nl|de</code> - Allowed values are <code>nl</code> (default value) and <code>de</code>. In some cases, especially in the south and east of Germany, <code>de</code> returns values at all.</p>
  </li>
  <li>
    <p><a name="interval" id="interval"></a> <code>interval 10|60|120|180|240|300</code> - Data update every <var>n</var> seconds. <strong>Attention!</strong> 10 seconds is a very aggressive value and should be chosen carefully, <abbr>e.g.</abbr> when troubleshooting. The default value is 120 seconds.</p>
  </li>
</ul>
<h3>Visualisation</h3>
<p>Buienradar offers besides the usual view as device also the possibility to visualize the data as charts in different formats. * An HTML version that is displayed in the detail view by default and can be viewed with</p>
<pre><code>    { FHEM::Buienradar::HTML("buienradar device name")}

can be retrieved.</code></pre>
<ul>
  <li>
    <p>A chart generated by Google Charts in <abbr>PNG</abbr> format, which can be viewed with</p>
    <pre><code>  { FHEM::Buienradar::GChart("buienradar device name")}</code></pre>
    <p>can be retrieved. <strong>Caution!</strong> Please note that data is transferred to Google for this purpose!</p>
  </li>
  <li>
    <p><abbr>FTUI</abbr> is supported by the LogProxy format:</p>
    <pre><code>  { FHEM::Buienradar::LogProxy("buienradar device name")}</code></pre>
  </li>
  <li>
    <p>A plain text representation can be displayed with</p>
    <pre><code>  { FHEM::Buienradar::TextChart(q{buienradar device name}, q{bar chart character})}</code></pre>
    <p>The bar chart character is optional and defaults to <code>=</code>.</p>
    <p>Every line represents a record of the whole set, i.e. if called by</p>
    <pre><code>  { FHEM::Buienradar::TextChart(q{buienradar_test_device}, q{#})}</code></pre>
    <p>the result will look similar to</p>
    <pre><code>  22:25 |   0.060 | #
  22:30 |   0.370 | ####
  22:35 |   0.650 | #######</code></pre>
    <p>For every 0.1 mm/h precipitation a <code>#</code> is displayed, but the output is capped to 50 units. If more than 50 units would be display, the bar is truncated and appended with a <code>&gt;</code>.</p>
    <pre><code>  23:00 |  11.800 | ##################################################&gt;</code></pre>
  </li>
</ul>

=end html

=begin html_DE

<p><a name="Buienradar" id="Buienradar"></a></p>
<h2>Buienradar</h2>
<p>Das Buienradar-Modul bindet die Niederschlagsvorhersagedaten der freien <abbr title="Application Program Interface">API</abbr> von <a href="https://www.buienradar.nl">Buienradar.nl</a> an.</p>
<p><span id="Buienradardefine"></span></p>
<h3>Define</h3>
<pre><code>define &lt;devicename&gt; Buienradar [latitude] [longitude]</code></pre>
<p>Die Werte für latitude und longitude sind optional und werden, wenn nicht explizit angegeben, von <var>global</var> bezogen. Die minimalste Definition lautet demnach:</p>
<pre><code>define &lt;devicename&gt; Buienradar</code></pre>
<p><span id="Buienradarset"></span></p>
<h3>Set</h3>
<p>Folgende Set-Aufrufe werden unterstützt:</p>
<ul>
  <li><code>refresh</code> - Neue Daten abfragen.</li>
</ul>
<p><span id="Buienradarget"></span></p>
<h3>Get</h3>
<p>Aktuell lassen sich folgende Daten mit einem Get-Aufruf beziehen:</p>
<ul>
  <li><code>rainDuration</code> - Die voraussichtliche Dauer des nächsten Niederschlags in Minuten.</li>
  <li><code>startsIn</code> - Der nächste Niederschlag beginnt in <var>n</var> Minuten. <strong>Obsolet!</strong></li>
  <li><code>version</code> - Aktuelle Version abfragen.</li>
</ul>
<p><span id="Buienradarreadings"></span></p>
<h3>Readings</h3>
<p>Aktuell liefert Buienradar folgende Readings:</p>
<ul>
  <li>
    <p><code>rainAmount</code> - Menge des gemeldeten Niederschlags in mm/h für den nächsten 5-Minuten-Intervall.</p>
  </li>
  <li>
    <p><code>rainBegin</code> - Beginn des nächsten Niederschlag. Wenn kein Niederschlag gemeldet ist, <var>unknown</var>.</p>
  </li>
  <li>
    <p><code>raindEnd</code> - Ende des nächsten Niederschlag. Wenn kein Niederschlag gemeldet ist, <var>unknown</var>.</p>
  </li>
  <li>
    <p><code>rainDataStart</code> - Zeitlicher Beginn der gelieferten Niederschlagsdaten.</p>
  </li>
  <li>
    <p><code>rainDataEnd</code> - Zeitliches Ende der gelieferten Niederschlagsdaten.</p>
  </li>
  <li>
    <p><code>rainLaMetric</code> - Aufbereitete Daten für LaMetric-Devices.</p>
  </li>
  <li>
    <p><code>rainMax</code> - Die maximale Niederschlagsmenge in mm/h für ein 5 Min. Intervall auf Basis der vorliegenden Daten.</p>
  </li>
  <li>
    <p><code>rainNow</code> - Die vorhergesagte Niederschlagsmenge für das aktuelle 5 Min. Intervall in mm/h.</p>
  </li>
  <li>
    <p><code>rainTotal</code> - Die gesamte vorhergesagte Niederschlagsmenge in mm/h</p>
  </li>
  <li>
    <p><code>rainDuration</code> - Dauer der gemeldeten Niederschläge in Minuten</p>
  </li>
  <li>
    <p><code>rainDurationTime</code> - Dauer der gemeldeten Niederschläge in HH:MM</p>
  </li>
  <li>
    <p><code>rainDurationIntervals</code> - Anzahl der Intervalle mit gemeldeten Niederschlägen</p>
  </li>
  <li>
    <p><code>rainDurationPercent</code> - Prozentualer Anteil der Intervalle mit Niederschlägen</p>
  </li>
</ul>
<p><span id="Buienradarattr"></span></p>
<h3>Attribute</h3>
<ul>
  <li>
    <p><a name="disabled" id="disabled"></a> <code>disabled on|off</code> - Wenn <code>disabled</code> auf <code>on</code> gesetzt wird, wird das Device keine weiteren Anfragen mehr an Buienradar.nl durchführen. <code>off</code> reaktiviert das Modul, ebenso wenn das Attribut gelöscht wird.</p>
    <p><strong>Achtung!</strong> Aus Kompatibilitätsgründen zu <code>FHEM::IsDisabled()</code> wird bei einem Aufruf von <code>disabled</code> auch <code>disable</code> als weiteres Attribut gesetzt. Wird <code>disable</code> gesetzt oder gelöscht, beeinflusst dies <code>disabled</code> nicht! <em><code>disable</code> sollte nicht verwendet werden!</em></p>
  </li>
  <li>
    <p><a name="region" id="region"></a> <code>region nl|de</code> - Erlaubte Werte sind <code>nl</code> (Standardwert) und <code>de</code>. In einigen Fällen, insbesondere im Süden und Osten Deutschlands, liefert <code>de</code> überhaupt Werte.</p>
  </li>
  <li>
    <p><a name="interval" id="interval"></a> <code>interval 10|60|120|180|240|300</code> - Aktualisierung der Daten alle <var>n</var> Sekunden. <strong>Achtung!</strong> 10 Sekunden ist ein sehr aggressiver Wert und sollte mit Bedacht gewählt werden, <abbr>z.B.</abbr> bei der Fehlersuche. Standardwert sind 120 Sekunden.</p>
  </li>
</ul>
<h3>Visualisierungen</h3>
<p>Buienradar bietet neben der üblichen Ansicht als Device auch die Möglichkeit, die Daten als Charts in verschiedenen Formaten zu visualisieren. * Eine HTML-Version die in der Detailansicht standardmäßig eingeblendet wird und mit</p>
<pre><code>    { FHEM::Buienradar::HTML("name des buienradar device")}
    
abgerufen werden.</code></pre>
<ul>
  <li>
    <p>Ein von Google Charts generiertes Diagramm im <abbr>PNG</abbr>-Format, welcher mit</p>
    <pre><code>  { FHEM::Buienradar::GChart("name des buienradar device")}</code></pre>
    <p>abgerufen werden kann. <strong>Achtung!</strong> Dazu werden Daten an Google übertragen!</p>
  </li>
  <li>
    <p>Für <abbr>FTUI</abbr> werden die Daten im LogProxy-Format bereitgestellt:</p>
    <pre><code>  { FHEM::Buienradar::LogProxy("name des buienradar device")}</code></pre>
  </li>
  <li>
    <p>Für eine reine Text-Ausgabe der Daten als Graph, kann</p>
    <pre><code>  { FHEM::Buienradar::TextChart(q{name des buienradar device}, q{verwendetes zeichen})}</code></pre>
    <p>verwendet werden. Das <code>verwendete zeichen</code> ist optional und mit <code>=</code> vorbelegt. Ausgegeben wird beispielsweise für den Aufruf</p>
    <pre><code>  { FHEM::Buienradar::TextChart(q{buienradar_test}, q{#}) }</code></pre>
    <p>für jeden Datensatz eine Zeile im Muster</p>
    <pre><code>  22:25 |   0.060 | #
  22:30 |   0.370 | ###
  22:35 |   0.650 | #######</code></pre>
    <p>wobei für jede 0.1 mm/h Niederschlag das <code>#</code> verwendet wird, maximal jedoch 50 Einheiten. Mehr werden mit einem <code>&gt;</code> abgekürzt.</p>
    <pre><code>  23:00 |  11.800 | ##################################################&gt;</code></pre>
  </li>
</ul>

=end html_DE

=cut

=for :application/json;q=META.json 59_Buienradar.pm
{
    "abstract": "FHEM module for precipitation forecasts basing on buienradar.nl",
    "x_lang": {
        "de": {
            "abstract": "FHEM-Modul f&uuml;r Regen- und Regenmengenvorhersagen auf Basis von buienradar.nl"
        }
    },
    "keywords": [
        "Buienradar",
        "Precipitation",
        "Rengenmenge",
        "Regenvorhersage",
        "hoeveelheid regen",
        "regenvoorspelling",
        "Niederschlag"
    ],
    "release_status": "development",
    "license": "Unlicense",
    "version": "3.0.8",
    "author": [
        "Christoph Morrison <post@christoph-jeschke.de>"
    ],
    "resources": {
        "homepage": "https://github.com/fhem/mod-Buienradar/",
        "x_homepage_title": "Module homepage",
        "license": [
            "https://github.com/fhem/mod-Buienradar/blob/master/LICENSE"
        ],
        "bugtracker": {
            "web": "https://github.com/fhem/mod-Buienradar/issues"
        },
        "repository": {
            "type": "git",
            "url": "https://github.com/fhem/mod-Buienradar.git",
            "web": "https://github.com/fhem/mod-Buienradar.git",
            "x_branch": "master",
            "x_development": {
                "type": "git",
                "url": "https://github.com/fhem/mod-Buienradar.git",
                "web": "https://github.com/fhem/mod-Buienradar/tree/development",
                "x_branch": "development"
            },
            "x_filepath": "",
            "x_raw": ""
        },
        "x_wiki": {
            "title": "Buienradar",
            "web": "https://wiki.fhem.de/wiki/Buienradar"
        }
    },
    "x_fhem_maintainer": [
        "jeschkec"
    ],
    "x_fhem_maintainer_github": [
        "christoph-morrison"
    ],
    "prereqs": {
        "runtime": {
            "requires": {
                "FHEM": 5.00918799,
                "perl": 5.10,
                "Meta": 0,
                "JSON::MaybeXS": 0,
                "Readonly": 0
            },
            "recommends": {
                "Cpanel::JSON::XS": 0
            },
            "suggests": {

            }
        }
    }
}
=end :application/json;q=META.json
