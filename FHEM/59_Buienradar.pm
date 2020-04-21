=pod

 This is free and unencumbered software released into the public domain.

  59_Buienradar.pm
       2018 lubeda
       2019 ff. Christoph Morrison, <fhem@christoph-jeschke.de>

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

=cut

# @todo
# ATM, it's not possible to comply to this Perl::Critic rule, because
# the current state of the FHEM API does require this bogus XX_Name.pm convention
package FHEM::Buienradar;   ## no critic (RequireFilenameMatchesPackage)

use strict;
use warnings;
use HttpUtils;
use JSON;
use List::Util;
use Time::Seconds;
use POSIX;
use Data::Dumper;
use English;
use Storable;
use GPUtils qw(GP_Import GP_Export);
use experimental qw( switch );
use 5.010;                                  # we do not want perl be older than from 2007
use Readonly;

=pod
    Settings
=cut
Readonly our $version               => '3.0.5';
Readonly our $default_interval      => ONE_MINUTE * 2;
Readonly our $debugging_min_verbose => 4;
Readonly our $default_region        => q{de};
Readonly our $default_bar_character => q{=};

=pod
    Translations
=cut
Readonly my %Translations => (
    'GChart' => {
        'hAxis'  => {
            'de' => 'Uhrzeit',
            'en' => 'Time',
        },
        'vAxis'  => {
            'de' => 'mm/h',
            'en' => 'mm/h',
        },
        'title'  => {
            'de' => 'Niederschlagsvorhersage für %s, %s',
            'en' => 'Precipitation forecast for %s, %s',
        },
        'legend' => {
            'de' => 'Niederschlag',
            'en' => 'Precipitation',
        },
    },
    'Attr'    => {
        'interval' => {
            'de' => 'ist kein valider Wert für den Intervall. Einzig 10, 60, 120, 180, 240 oder 300 sind erlaubt!',
            'en' => 'is no valid value for interval. Only 10, 60, 120, 180, 240 or 300 are allowed!',
        },
        'region'   => {
            'de' => q{ist kein valider Wert für die Region. Einzig 'de' oder 'nl' werden unterstützt!},
            'en' => q{is no valid value for region. Only 'de' or 'nl' are allowed!},
        }
    },
);

=pod
    Global variables
=cut
my @errors;
my $global_hash;
my $language;


GP_Export(
    qw(
        Initialize
    )
);

# try to use JSON::MaybeXS wrapper
#   for chance of better performance + open code
my $eval_return;

$eval_return = eval {
    require JSON::MaybeXS;
    import JSON::MaybeXS qw( decode_json encode_json );
    1;
};

if (!$eval_return) {
    local $@ = undef;

    # try to use JSON wrapper
    #   for chance of better performance
    $eval_return = eval {

        # JSON preference order
        local $ENV{PERL_JSON_BACKEND} =
            q{Cpanel::JSON::XS,JSON::XS,JSON::PP,JSON::backportPP}
            unless ( defined( $ENV{PERL_JSON_BACKEND} ) );

        require JSON;
        import JSON qw( decode_json encode_json );
        1;
    };

    if (!$eval_return) {
        local $@ = undef;

        # In rare cases, Cpanel::JSON::XS may
        #   be installed but JSON|JSON::MaybeXS not ...
        $eval_return = eval {
            require Cpanel::JSON::XS;
            import Cpanel::JSON::XS qw(decode_json encode_json);
            1;
        };

        if (!$eval_return) {
            local $@ = undef;

            # In rare cases, JSON::XS may
            #   be installed but JSON not ...
            $eval_return = eval {
                require JSON::XS;
                import JSON::XS qw(decode_json encode_json);
                1;
            };

            if (!$eval_return) {
                local $@ = undef;

                # Fallback to built-in JSON which SHOULD
                #   be available since 5.014 ...
                $eval_return = eval {
                    require JSON::PP;
                    import JSON::PP qw(decode_json encode_json);
                    1;
                };

                if (!$eval_return) {
                    local $@ = undef;

                    # Fallback to JSON::backportPP in really rare cases
                    require JSON::backportPP;
                    import JSON::backportPP qw(decode_json encode_json);
                    1;
                }
            }
        }
    }
}

#####################################
sub Initialize {

    my ($hash) = @_;

    $hash->{DefFn}       = \&FHEM::Buienradar::Define;
    $hash->{UndefFn}     = \&FHEM::Buienradar::Undefine;
    $hash->{GetFn}       = \&FHEM::Buienradar::Get;
    $hash->{SetFn}       = \&FHEM::Buienradar::Set;
    $hash->{AttrFn}      = \&FHEM::Buienradar::Attr;
    $hash->{FW_detailFn} = \&FHEM::Buienradar::Detail;
    $hash->{AttrList}    = join(q{ },
        (
            'disabled:on,off',
            'region:nl,de',
            'interval:10,60,120,180,240,300'
        )
    ) . qq[ $::readingFnAttributes ];
    $hash->{REGION} = $default_region;

    return;
}

sub Detail {
    my ( $FW_wname, $name, $room, $pageHash ) =
      @_;    # pageHash is set for summaryFn.
    my $hash = GetHash($name);

    return if ( !defined( $hash->{URL} ) );

    # @todo error in the second return: missing target attribute
    # @todo I18N
    if (::ReadingsVal($hash->{NAME}, 'rainData', 'unknown') ne 'unknown') {
        return
            HTML($hash->{NAME}) . qq[<p><a href="$hash->{URL}" target="_blank">Raw JSON data (new window)</a></p> ]
    } else {
        return qq[<div><a href="$hash->{URL}">Raw JSON data (new window)</a></div>];
    }
}

#####################################
sub Undefine {
    my ( $hash, $arg ) = @_;
    ::RemoveInternalTimer( $hash, \&FHEM::Buienradar::Timer );
    return;
}

=pod

    Create a human readable representation for a given time t, like x minutes, y seconds, but only
    with the necessary pieces.

    Respects your wishes regarding scalar / list context, e.g.

    # list context
    say Dumper(timediff2str(10000))
        $VAR1 = '1';
        $VAR2 = '3';
        $VAR3 = '46';
        $VAR4 = '40';

    # scalar context
    say Dumper(scalar timediff2str(100000));
        $VAR1 = '1 Tage, 03 Stunden, 46 Minuten, 40 Sekunden';

=cut
sub timediff2str {
    my $s = shift;

    return unless defined wantarray;
    return unless defined $s;

    return (
        wantarray
            ?   (0,0,0,$s)
            : sprintf '%02d Sekunden', $s
    ) if $s < 60;

    my $m = $s / 60; $s = $s % 60;
    return (
        wantarray
            ?   (0, 0, POSIX::floor($m), POSIX::floor($s))
            :   sprintf '%02d Minuten, %02d Sekunden', $m, $s
    ) if $m < 60;

    my $h = $m /  60; $m %= 60;
    return (
        wantarray
            ?   (0, POSIX::floor($h), POSIX::floor($m), POSIX::floor($s))
            :   sprintf '%02d Stunden, %02d Minuten, %02d Sekunden', $h, $m, $s
    ) if $h < 24;

    my $d = $h / 24; $h %= 24;
    return (
        wantarray
            ?   ( POSIX::floor($d), POSIX::floor($h), POSIX::floor($m), POSIX::floor($s))
            :   sprintf '%d Tage, %02d Stunden, %02d Minuten, %02d Sekunden', $d, $h, $m, $s
    );
}

## no critic (ProhibitPackageVars)
=pod

@todo
Accesses $::defs. This is just a kludge for the non-existen FHEM API to access device details
Should be fixed if possible!

=cut
sub GetHash {

    my $name = shift;
    return $::defs{$name};
}

=pod

@todo
Accesses $::defs{$device}{disable}. This is just a kludge for the non-existen FHEM API to access device details
Should be fixed if possible!

=cut
sub Disable {
    my $name = shift;
    $::attr{$name}{'disable'} = 1;
    return;
}

=pod

@todo
Accesses $::defs{$device}{disable}. This is just a kludge for the non-existen FHEM API to access device details
Should be fixed if possible!

=cut
sub Enable {
    my $name = shift;
    $::attr{$name}{'disable'} = 0;
    return;
}
## use critic

###################################
sub Set {
    my ( $hash, $name, $opt, @args ) = @_;
    return qq['set $name' needs at least one argument] unless ( defined($opt) );

    given ($opt) {
        when ('refresh') {
            RequestUpdate($hash);
            return q{};
        }

        default {
            return 'Unknown argument $opt, choose one of refresh:noArg';
        }
    }

    return qq{Unknown argument $opt, choose one of refresh:noArg};
}

sub Get {

    my ( $hash, $name, $opt, @args ) = @_;

    return qq['get $name' needs at least one argument] unless ( defined($opt) );

    given($opt)
    {
        when ('version') {
            return $version;
        }

        # @todo I18N
        when ('startsIn') {
            my $begin = $hash->{'.RainStart'};
            return q[No data available] unless $begin;
            return q[It is raining] if $begin == 0;

            my $timeDiffSec = $begin - time;
            return scalar timediff2str($timeDiffSec);
        }
    }

    if ( $opt eq 'rainDuration' ) {
        return ::ReadingsVal($name, 'rainDuration', 'unknown');
    }
    else {
        return qq[Unknown argument $opt, choose one of version:noArg startsIn:noArg rainDuration:noArg];
    }

    return;
}

sub Attr {
    my ($command, $name, $attribute_name, $attribute_value) = @_;
    my $hash = GetHash($name);
    
    Debugging($name, Dumper({
        command     =>  $command,
        device      =>  $name,
        attribute   =>  $attribute_name,
        value       =>  $attribute_value
    }));

    given ($attribute_name) {
        # JFTR: disabled will also set disable to be compatible to FHEM::IsDisabled()
        #       This is a ugly hack, with some side-effects like you can set disabled, disable will be automatically
        #       set, you can delete disable but disabled will still be set.
        when ('disabled') {
            given ($command) {
                when ('set') {
                    return qq[${attribute_value} is not a valid value for disabled. Only 'on' or 'off' are allowed!]
                        if $attribute_value !~ /^(?: on | off | 0 | 1 )$/x;

                    if ($attribute_value =~ /(?: on | 1)/x) {
                        ::RemoveInternalTimer( $hash,\&FHEM::Buienradar::Timer );
                        Disable($name);
                        $hash->{NEXTUPDATE} = undef;
                        $hash->{STATE} = 'inactive';
                        return;
                    }

                    if ($attribute_value =~ /(off|0)/x) {
                        Enable($name);
                        Timer($hash);
                        return;
                    }
                }

                when ('del') {
                    Enable($name);
                    Timer($hash);
                }
            }
        }

        when ('region') {
            return Error($name, qq[${attribute_value} ${FHEM::Buienradar::Translations{'Attr'}{'region'}{$language}}])
                if $attribute_value !~ /^(?: de | nl )$/x and $command eq 'set';

            given ($command) {
                when ('set') {
                    $hash->{REGION} = $attribute_value;
                }

                when ('del') {
                    $hash->{REGION} = 'nl';
                }
            }

            RequestUpdate($hash);
            return;
        }

        when ('interval') {
            return Error($name, qq[${attribute_value} ${FHEM::Buienradar::Translations{'Attr'}{'interval'}{$language}}])
                if $attribute_value !~ /^(?: 10 | 60 | 120 | 180 | 240 | 300 )$/x and $command eq 'set';

            given ($command) {
                when ('set') {
                    $hash->{INTERVAL} = $attribute_value;
                }

                when ('del') {
                    $hash->{INTERVAL} = $default_interval;
                }
            }

            Timer($hash);
            return;
        }

    }

    return;
}

#####################################
sub Define {

    my ( $hash, $def ) = @_;
    $global_hash = $hash;

    my @a = split( '[ \t][ \t]*', $def );
    my $latitude;
    my $longitude;

    if ( ( int(@a) == 2 ) && ( ::AttrVal( 'global', 'latitude', -255 ) != -255 ) )
    {
        $latitude  = ::AttrVal( 'global', 'latitude',  51.0 );
        $longitude = ::AttrVal( 'global', 'longitude', 7.0 );
    }
    elsif ( int(@a) == 4 ) {
        $latitude  = $a[2];
        $longitude = $a[3];
    }
    else {
        # @todo this looks bogus and unnecessary
        return int(@a) . q{Syntax: define <name> Buienradar [<latitude> <longitude>]};
    }

    ::readingsSingleUpdate($hash, 'state', 'Initialized', 1);

    my $name = $a[0];
    $hash->{NAME}       = $name;
    $hash->{VERSION}    = $version;
    $hash->{INTERVAL}   = $default_interval;
    $hash->{LATITUDE}   = $latitude;
    $hash->{LONGITUDE}  = $longitude;
    $hash->{URL}        = undef;
    # get language for language dependend legend
    $language = lc ::AttrVal('global', 'language', 'DE');

    ::readingsBeginUpdate($hash);
        ::readingsBulkUpdate( $hash, 'rainNow', 'unknown' );
        ::readingsBulkUpdate( $hash, 'rainDataStart', 'unknown');
        ::readingsBulkUpdate( $hash, 'rainBegin', 'unknown');
        ::readingsBulkUpdate( $hash, 'rainEnd', 'unknown');
    ::readingsEndUpdate( $hash, 1 );

    # set default region nl
    ::CommandAttr(undef, qq[$name region nl])
        unless (::AttrVal($name, 'region', undef));

    ::CommandAttr(undef, qq[$name interval $FHEM::Buienradar::default_interval])
        unless (::AttrVal($name, 'interval', undef));

    Timer($hash);

    return;
}

sub Timer {
    my ($hash) = @_;
    my $nextupdate = 0;

    ::RemoveInternalTimer( $hash, \&FHEM::Buienradar::Timer );

    $nextupdate = int( time() + $hash->{INTERVAL} );
    $hash->{NEXTUPDATE} = ::FmtDateTime($nextupdate);
    RequestUpdate($hash);

    ::InternalTimer( $nextupdate, \&FHEM::Buienradar::Timer, $hash );

    return 1;
}

sub RequestUpdate {
    my ($hash) = @_;
    my $region = $hash->{REGION};

    # @todo candidate for refactoring to sprintf
    $hash->{URL} =
      ::AttrVal( $hash->{NAME}, 'BaseUrl', 'https://cdn-secure.buienalarm.nl/api/3.4/forecast.php' )
        . '?lat='       . $hash->{LATITUDE}
        . '&lon='       . $hash->{LONGITUDE}
        . '&region='    . $region
        . '&unit='      . 'mm/u';

    my $param = {
        url      => $hash->{URL},
        timeout  => 10,
        hash     => $hash,
        method   => 'GET',
        callback => \&ParseHttpResponse
    };

    ::HttpUtils_NonblockingGet($param);
    Debugging($hash->{NAME}, q{Data update requested});

    return;
}

sub HTML {
    my ( $name, $width ) = @_;
    my $hash = GetHash($name);
    my @values = split /:/x, ::ReadingsVal($name, 'rainData', '0:0');

    my $as_html = <<'END_MESSAGE';
<style>

.BRchart div {
  font: 10px sans-serif;
  background-color: steelblue;
  text-align: right;
  padding: 3px;
  margin: 1px;
  color: white;
}
 
</style>
<div class='BRchart'>
END_MESSAGE

    # @todo the html looks terribly ugly
    $as_html .= qq[<BR>Niederschlag (<a href=./fhem?detail=$name>$name</a>)<BR>];

    $as_html .= ::ReadingsVal( $name, 'rainDataStart', 'unknown' ) . '<BR>';
    my $factor =
      ( $width ? $width : 700 ) / ( 1 + ::ReadingsVal( $name, 'rainMax', q{0} ) );
    foreach my $val (@values) {
        # @todo candidate for refactoring to sprintf
        $as_html .=
            q{<div style='width: }
          . ( int( $val * $factor ) + 30 )
          . q{px;'>}
          . sprintf( '%.3f', $val )
          . q{</div>};
    }

    $as_html .= q[</DIV><BR>];
    return ($as_html);
}

=pod

=cut
sub GetGChartDataSet {
    my $start = shift;
    my $precipitation = shift;

    my ($k, $v) = (
        POSIX::strftime('%H:%M', localtime $start),
        sprintf('%.3f', $precipitation)
    );

    return qq{['$k', $v]}
}

=over 1

=item C<FHEM::Buienradar::GChart>

=back

C<FHEM::Buienradar::GChart> returns the precipitation data from buienradar.nl as PNG, renderd by Google Charts as
a PNG data.

=cut
sub GChart {
    my $name = shift;
    my $hash = GetHash($name);

    unless ($hash->{'.SERIALIZED'}) {
        Error($name, q{Can't return serizalized data for FHEM::Buienradar::GChart.});

        # return dummy data
        return;
    }

    # read & parse stored data
    my %storedData = %{ Storable::thaw($hash->{'.SERIALIZED'}) };
    my $data = join ', ', map {
        GetGChartDataSet($storedData{$_}{'start'}, $storedData{$_}{'precipitation'});
    } sort keys %storedData;

    # create data for the GChart
    my $hAxis   = $Translations{'GChart'}{'hAxis'}{$language};
    my $vAxis   = $Translations{'GChart'}{'vAxis'}{$language};
    my $title   = sprintf(
        $Translations{'GChart'}{'title'}{$language},
        $hash->{LATITUDE},
        $hash->{LONGITUDE}
    );
    my $legend  = $Translations{'GChart'}{'legend'}{$language};

    return <<"CHART"
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
                title: '${hAxis}',
                slantedText:true,
                slantedTextAngle: 45,
                textStyle: {
                    fontSize: 10}
            },
            vAxis: {
                minValue: 0,
                title: '${vAxis}'
            }
        };

        var my_div = document.getElementById(
            'chart_${name}');        var chart = new google.visualization.AreaChart(my_div);
        google.visualization.events.addListener(chart, 'ready', function () {
            my_div.innerHTML = '<img src='' + chart.getImageURI() + ''>';
        });

        chart.draw(data, options);}
</script>

CHART
}

=over 1

=item C<FHEM::Buienradar::LogProxy>

C<FHEM::Buienradar::LogProxy> returns FHEM log look-alike data from the current data for using it with
FTUI. It returns a list containing three elements:

=back

=over 1

=item Log look-alike data, like

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

=item Fixed value of 0

=item Maximal amount of rain in a 5 minute interval

=back

=cut
sub LogProxy {
    my $name = shift;
    my $hash = GetHash($name);

    unless ($hash->{'.SERIALIZED'}) {
        Error($name, q{Can't return serizalized data for FHEM::Buienradar::LogProxy. Using dummy data});

        # return dummy data
        return (0, 0, 0);
    }

    my %data = %{ Storable::thaw($hash->{'.SERIALIZED'}) };

    return (
        join('\n', map {
            join(
                q{ }, (
                    POSIX::strftime('%F_%T', localtime $data{$_}{'start'}),
                    sprintf('%.3f', $data{$_}{'precipitation'})
                )
            )
        } keys %data),
        0,
        ::ReadingsVal($name, 'rainMax', 0)
    );
}

=pod

=over 1

=item C<FHEM::Buienradar::TextChart>

C<FHEM::Buienradar::TextChart> returns the precipitation data as textual chart representation

=back

=over 1

=item Example

=begin text

8:25 |   0.000 |
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

=item Fixed value of 0

=item Maximal amount of rain in a 5 minute interval

=back
=cut
sub TextChart {
    my $name = shift;
    my $bar_character = shift || $default_bar_character;
    my $hash = GetHash($name);

    unless ($hash->{'.SERIALIZED'}) {
        Error($name, q{Can't return serizalized data for FHEM::Buienradar::TextChart.});
        # return dummy data
        return
    }

    my %storedData = %{ Storable::thaw($hash->{'.SERIALIZED'}) };

    my ($time, $precip, $bar);
    my $data = join qq{\n}, map {
        join ' | ', ShowTextChartBar(%{ Storable::thaw($hash->{'.SERIALIZED'}) }, $bar_character);
    } sort keys %storedData;

    return $data;
}

=pod
    Build the char bar for the text chart
=cut
sub ShowTextChartBar {
    my %storedData = shift;
    my $bar_character = shift;

    my ($time, $precip, $bar) = (
        POSIX::strftime('%H:%M', localtime $storedData{$_}{'start'}),
        sprintf('% 7.3f', $storedData{$_}{'precipitation'}),
        (
            ($storedData{$_}{'precipitation'} < 50)
                ? $bar_character x  POSIX::lround(abs($storedData{$_}{'precipitation'} * 10))
                : ($bar_character x  50) . q{>}
        ),
    );

    return ($time, $precip, $bar);
}

## no critic (ProhibitExcessComplexity)
=pod
    @todo
    Must be
=cut
sub ParseHttpResponse {
    my ( $param, $err, $data ) = @_;
    my $hash = $param->{hash};
    my $name = $hash->{NAME};
    $hash->{'.RainStart'} = undef;

    my %precipitation_forecast;

    if ( $err ne q{} ) {
        ::readingsSingleUpdate($hash, 'state', qq[Error: $err =>$data], 1);
        ResetResult($hash);
    }
    elsif ( $data ne q{} ) {
        my $forecast_data;
        my $error;

        if(defined $param->{'code'} && $param->{'code'} ne '200') {
            $error = sprintf(
                'Pulling %s returns HTTP status code %d instead of 200.',
                $hash->{URL},
                $param->{'code'}
            );

            Debugging($name, qq[HTTP Response code is: $param->{'code'}]);

            if ($param->{'code'} eq '404') {
                my $response_body;
                $response_body = eval { $response_body = from_json($data) } unless @errors;

                unless ($@) {
                    Debugging($name, qq{Repsonse body}, Dumper($response_body));
                    $error = qq[Location is not in coverage for region '$hash->{REGION}'];
                }
            }

            Error($name, qq{$error});
            Debugging($name, Dumper($param));
            ::readingsSingleUpdate($hash, 'state', $error, 1);
            ResetResult($hash);
            return;
        }

        $forecast_data = eval { $forecast_data = from_json($data) } unless @errors;

        if ($@) {

            $error = qq{Can't evaluate JSON from $hash->{URL}: $@};
            Error($name, qq{$error});
            Debugging($name, join(q{}, map { qq{[$name] $_} } Dumper($data)));
            ::readingsSingleUpdate($hash, q{state}, $error, 1);
            ResetResult($hash);
            return;
        }

        unless ($forecast_data->{'success'}) {
            $error = q{Got JSON from buienradar.nl, but had some troubles delivering meaningful data!};
            Error($name, qq{$error});
            Debugging($name, join(q{}, map { qq{[$name] $_} } Dumper($data)));
            ::readingsSingleUpdate($hash, 'state', $error, 1);
            ResetResult($hash);
            return;
        }

        my @precip;
        @precip = @{$forecast_data->{'precip'}} unless @errors;

        Debugging($name, q{Received data: } . Dumper(@{$forecast_data->{'precip'}}));

        if (scalar @precip > 0) {
            my $rainLaMetric        = join(q{,}, map {$_ * 1000} @precip[0..11]);
            my $rainTotal           = List::Util::sum @precip;
            my $rainMax             = List::Util::max @precip;
            my $rainStart           = undef;
            my $rainEnd             = undef;
            my $dataStart           = $forecast_data->{start};
            my $dataEnd             = $dataStart + (scalar @precip) * 5 * ONE_MINUTE;
            my $forecast_start      = $dataStart;
            my $rainNow             = undef;
            my $rainData            = join(q{:}, @precip);
            my $rainAmount          = $precip[0];
            my $isRaining           = undef;
            my $intervalsWithRain   = scalar map { $_ > 0 ? $_ : () } @precip;
            $hash->{'.RainStart'}   = q{unknown};

            for (my $precip_index = 0; $precip_index < scalar @precip; $precip_index++) {

                my $start           = $forecast_start + $precip_index * 5 * ONE_MINUTE;
                my $end             = $start + 5 * ONE_MINUTE;
                my $precip          = $precip[$precip_index];
                $isRaining          = undef;                            # reset

                # set a flag if it's raining
                if ($precip > 0) {
                    $isRaining = 1;
                }

                # there is precipitation and start is not yet set
                if (not $rainStart and $isRaining) {
                    $rainStart  = $start;
                    $hash->{'.RainStart'} = $rainStart;
                }

                # It's raining again, so we have to reset rainEnd for a new chance
                if ($isRaining and $rainEnd) {
                    $rainEnd    = undef;
                }

                # It's not longer raining, so set rainEnd (again)
                if ($rainStart and not $isRaining and not $rainEnd) {
                    $rainEnd    = $start;
                }

                if (time() ~~ [$start..$end]) {
                    $rainNow    = $precip;
                    $hash->{'.RainStart'} = 0;
                }

                $precipitation_forecast{$start} = {
                    'start'         => $start,
                    'end'           => $end,
                    'precipitation' => $precip,
                };
            }

            Debugging($name, Dumper(%precipitation_forecast));

            $hash->{'.SERIALIZED'} = Storable::freeze(\%precipitation_forecast);

            ::readingsBeginUpdate($hash);
                ::readingsBulkUpdate( $hash, 'state', (($rainNow) ? sprintf( '%.3f', $rainNow) : 'unknown'));
                ::readingsBulkUpdate( $hash, 'rainTotal', sprintf( '%.3f', $rainTotal) );
                ::readingsBulkUpdate( $hash, 'rainAmount', sprintf( '%.3f', $rainAmount) );
                ::readingsBulkUpdate( $hash, 'rainNow', (($rainNow) ? sprintf( '%.3f', $rainNow) : 'unknown'));
                ::readingsBulkUpdate( $hash, 'rainLaMetric', $rainLaMetric );
                ::readingsBulkUpdate( $hash, 'rainDataStart', POSIX::strftime '%R', localtime $dataStart);
                ::readingsBulkUpdate( $hash, 'rainDataEnd', POSIX::strftime '%R', localtime $dataEnd );
                ::readingsBulkUpdate( $hash, 'rainMax', sprintf( '%.3f', $rainMax ) );
                ::readingsBulkUpdate( $hash, 'rainBegin', (($rainStart) ? POSIX::strftime '%R', localtime $rainStart : 'unknown'));
                ::readingsBulkUpdate( $hash, 'rainEnd', (($rainEnd) ? POSIX::strftime '%R', localtime $rainEnd : 'unknown'));
                ::readingsBulkUpdate( $hash, 'rainData', $rainData);
                ::readingsBulkUpdate( $hash, 'rainDuration', $intervalsWithRain * 5);
                ::readingsBulkUpdate( $hash, 'rainDurationIntervals', $intervalsWithRain);
                ::readingsBulkUpdate( $hash, 'rainDurationPercent', ($intervalsWithRain / scalar @precip) * 100);
                ::readingsBulkUpdate( $hash, 'rainDurationTime', sprintf('%02d:%02d',(( $intervalsWithRain * 5 / 60), $intervalsWithRain * 5 % 60)));
            ::readingsEndUpdate( $hash, 1 );
        }
    }

    return;
}
## use critic

sub ResetResult {
    my $hash = shift;

    $hash->{'.SERIALIZED'} = undef;

    ::readingsBeginUpdate($hash);
        ::readingsBulkUpdate( $hash, 'rainTotal', 'unknown' );
        ::readingsBulkUpdate( $hash, 'rainAmount', 'unknown' );
        ::readingsBulkUpdate( $hash, 'rainNow', 'unknown' );
        ::readingsBulkUpdate( $hash, 'rainLaMetric', 'unknown' );
        ::readingsBulkUpdate( $hash, 'rainDataStart', 'unknown');
        ::readingsBulkUpdate( $hash, 'rainDataEnd', 'unknown' );
        ::readingsBulkUpdate( $hash, 'rainMax', 'unknown' );
        ::readingsBulkUpdate( $hash, 'rainBegin', 'unknown');
        ::readingsBulkUpdate( $hash, 'rainEnd', 'unknown');
        ::readingsBulkUpdate( $hash, 'rainData', 'unknown');
    ::readingsEndUpdate( $hash, 1 );

    return;
}

sub Debugging {
    local $OFS = qq{\n};
    my $device_name = shift;
    ::Debug(join($OFS, (qq{[$device_name]}, qq{@_}))) if (
        int(::AttrVal(q{global}, q{verbose}, 0)) >= $debugging_min_verbose
        or  int(::AttrVal($device_name, q{debug}, 0)) == 1
    );
    return;
}

sub Error {
    my $device_name = shift;
    my $message = shift || q{Something bad happened. Unknown error!};
    return qq{[$device_name] Error: $message};
}

1;

=pod

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
    <p>A plain text representation can be display by</p>
    <pre><code>  { FHEM::Buienradar::TextChart("buienradar device name")}</code></pre>
    <p>Every line represents a record of the whole set in a format like</p>
    <pre><code>  22:25 |   0.060 | =
  22:30 |   0.370 | ====
  22:35 |   0.650 | =======</code></pre>
    <p>For every 0.1 mm/h precipitation a <code>=</code> is displayed, but the output is capped to 50 units. If more than 50 units would be display, the bar is appended with a <code>&gt;</code>.</p>
    <pre><code>  23:00 |  11.800 | ==================================================&gt;</code></pre>
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
    <pre><code>  { FHEM::Buienradar::TextChart("name des buienradar device")}</code></pre>
    <p>verwendet werden. Ausgegeben wird ein für jeden Datensatz eine Zeile im Muster</p>
    <pre><code>  22:25 |   0.060 | =
  22:30 |   0.370 | ====
  22:35 |   0.650 | =======</code></pre>
    <p>wobei für jede 0.1 mm/h Niederschlag ein <code>=</code> ausgegeben wird, maximal jedoch 50 Einheiten. Mehr werden mit einem <code>&gt;</code> abgekürzt.</p>
    <pre><code>  23:00 |  11.800 | ==================================================&gt;</code></pre>
  </li>
</ul>

=end html_DE

=cut

=for :application/json;q=META.json 59_Buienradar.pm
{
    "abstract": "FHEM module for precipiation forecasts basing on buienradar.nl",
    "x_lang": {
        "de": {
            "abstract": "FHEM-Modul f&uuml;r Regen- und Regenmengenvorhersagen auf Basis von buienradar.nl"
        }
    },
    "keywords": [
        "Buienradar",
        "Precipiation",
        "Rengenmenge",
        "Regenvorhersage",
        "hoeveelheid regen",
        "regenvoorspelling",
        "Niederschlag"
    ],
    "release_status": "development",
    "license": "Unlicense",
    "version": "3.0.5",
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
                "JSON": 0
            },
            "recommends": {
            
            },
            "suggests": {
            
            }
        }
    }
}
=end :application/json;q=META.json
