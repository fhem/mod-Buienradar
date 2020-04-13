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

package FHEM::Buienradar;

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
use v5.10;
use Readonly;

=pod
    Settings
=cut
Readonly our $version => '3.0.4';
Readonly our $default_interval => ONE_MINUTE * 2;

=pod
    Translations
=cut
Readonly our %Translations => (
    'GChart' => {
        'hAxis' => {
            'de'    =>  'Uhrzeit',
            'en'    =>  'Time',
        },
        'vAxis' => {
            'de'    => 'mm/h',
            'en'    => 'mm/h',
        },
        'title' => {
            'de'    =>  'Niederschlagsvorhersage für %s, %s',
            'en'    =>  'Precipitation forecast for %s, %s',
        },
        'legend' => {
            'de'    => 'Niederschlag',
            'en'    => 'Precipitation',
        },
    }
);

=pod
    Global variables
=cut
our $device;
our @errors;

GP_Export(
    qw(
        Initialize
    )
);

# try to use JSON::MaybeXS wrapper
#   for chance of better performance + open code
eval {
    require JSON::MaybeXS;
    import JSON::MaybeXS qw( decode_json encode_json );
    1;
};

if ($@) {
    local $@ = undef;

    # try to use JSON wrapper
    #   for chance of better performance
    eval {

        # JSON preference order
        local $ENV{PERL_JSON_BACKEND} =
            q{Cpanel::JSON::XS,JSON::XS,JSON::PP,JSON::backportPP}
            unless ( defined( $ENV{PERL_JSON_BACKEND} ) );

        require JSON;
        import JSON qw( decode_json encode_json );
        1;
    };

    if ($@) {
        local $@ = undef;

        # In rare cases, Cpanel::JSON::XS may
        #   be installed but JSON|JSON::MaybeXS not ...
        eval {
            require Cpanel::JSON::XS;
            import Cpanel::JSON::XS qw(decode_json encode_json);
            1;
        };

        if ($@) {
            local $@ = undef;

            # In rare cases, JSON::XS may
            #   be installed but JSON not ...
            eval {
                require JSON::XS;
                import JSON::XS qw(decode_json encode_json);
                1;
            };

            if ($@) {
                local $@ = undef;

                # Fallback to built-in JSON which SHOULD
                #   be available since 5.014 ...
                eval {
                    require JSON::PP;
                    import JSON::PP qw(decode_json encode_json);
                    1;
                };

                if ($@) {
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

    $hash->{DefFn}       = 'FHEM::Buienradar::Define';
    $hash->{UndefFn}     = 'FHEM::Buienradar::Undefine';
    $hash->{GetFn}       = 'FHEM::Buienradar::Get';
    $hash->{SetFn}       = 'FHEM::Buienradar::Set';
    $hash->{AttrFn}      = 'FHEM::Buienradar::Attr';
    $hash->{FW_detailFn} = 'FHEM::Buienradar::Detail';
    $hash->{AttrList}    = join(q{ },
        (
            'disabled:on,off',
            'region:nl,de',
            'interval:10,60,120,180,240,300'
        )
    ) . qq[ $::readingFnAttributes ];
    $hash->{'.PNG'} = q{};
    $hash->{REGION} = 'de';

    return;
}

sub Detail {
    my ( $FW_wname, $d, $room, $pageHash ) =
      @_;    # pageHash is set for summaryFn.
    my $hash = $::defs{$d};

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
    ::RemoveInternalTimer( $hash, 'FHEM::Buienradar::Timer' );
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
sub timediff2str
{
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
            return q[It is raining] if $begin = 0;

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
    my ($command, $device_name, $attribute_name, $attribute_value) = @_;
    my $hash = $::defs{$device_name};

    Debugging(
        'Attr called', '\n',
        Dumper (
            $command, $device_name, $attribute_name, $attribute_value
        )
    );

    given ($attribute_name) {
        # JFTR: disabled will also set disable to be compatible to FHEM::IsDisabled()
        #       This is a ugly hack, with some side-effects like you can set disabled, disable will be automatically
        #       set, you can delete disable but disabled will still be set.
        when ('disabled') {
            Debugging(
                Dumper (
                    {
                        'attribute_value' => $attribute_value,
                        'attr' => 'disabled',
                        'command' => $command,
                    }
                )
            );

            given ($command) {
                when ('set') {
                    return qq[${attribute_value} is not a valid value for disabled. Only 'on' or 'off' are allowed!]
                        if $attribute_value !~ /^(on|off|0|1)$/;

                    if ($attribute_value =~ /(on|1)/) {
                        ::RemoveInternalTimer( $hash, 'FHEM::Buienradar::Timer' );
                        $::attr{$device_name}{'disable'} = 1;
                        $hash->{NEXTUPDATE} = undef;
                        $hash->{STATE} = 'inactive';
                        return;
                    }

                    if ($attribute_value =~ /(off|0)/) {
                        $::attr{$device_name}{'disable'} = 0;
                        Timer($hash);
                        return;
                    }
                }

                when ('del') {
                    delete $::attr{$device_name}{'disable'};
                    Timer($hash) if $attribute_value eq 'off';
                }
            }
        }

        when ('region') {
            return qq[${attribute_value} is no valid value for region. Only 'de' or 'nl' are allowed!]
                if $attribute_value !~ /^(de|nl)$/ and $command eq 'set';

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
            return q[${attribute_value} is no valid value for interval. Only 10, 60, 120, 180, 240 or 300 are allowed!]
                if $attribute_value !~ /^(10|60|120|180|240|300)$/ and $command eq 'set';

            given ($command) {
                when ('set') {
                    $hash->{INTERVAL} = $attribute_value;
                }

                when ('del') {
                    $hash->{INTERVAL} = $FHEM::Buienradar::default_interval;
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
    $device = $name;

    $hash->{VERSION}    = $version;
    $hash->{INTERVAL}   = $FHEM::Buienradar::default_interval;
    $hash->{LATITUDE}   = $latitude;
    $hash->{LONGITUDE}  = $longitude;
    $hash->{URL}        = undef;
    # @todo this looks like a good candidate for a refactoring
    $hash->{'.HTML'}    = '<DIV>';

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

    ::RemoveInternalTimer( $hash, 'FHEM::Buienradar::Timer' );

    $nextupdate = int( time() + $hash->{INTERVAL} );
    $hash->{NEXTUPDATE} = ::FmtDateTime($nextupdate);
    RequestUpdate($hash);

    ::InternalTimer( $nextupdate, 'FHEM::Buienradar::Timer', $hash );

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
    ::Log3( $hash->{NAME}, 4, qq[$hash->{NAME}: Update requested] );

    return;
}

sub HTML {
    my ( $name, $width ) = @_;
    my $hash = $::defs{$name};
    my @values = split /:/, ::ReadingsVal($name, 'rainData', '0:0');

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

=over 1

=item C<FHEM::Buienradar::GChart>

=back

C<FHEM::Buienradar::GChart> returns the precipitation data from buienradar.nl as PNG, renderd by Google Charts as
a PNG data.

=cut
sub GChart {
    my $name = shift;
    my $hash = $::defs{$name};

    unless ($hash->{'.SERIALIZED'}) {
        ::Log3($name, 3,
            sprintf(
                q{[%s] Can't return serizalized data for FHEM::Buienradar::GChart.},
                $name
            )
        );

        # return dummy data
        return;
    }

    # read & parse stored data
    my %storedData = %{ Storable::thaw($hash->{'.SERIALIZED'}) };
    my $data = join ', ', map {
        my ($k, $v) = (
            POSIX::strftime('%H:%M', localtime $storedData{$_}{'start'}),
            sprintf('%.3f', $storedData{$_}{'precipitation'})
        );
        qq{['$k', $v]}
    } sort keys %storedData;

    # get language for language dependend legend
    my $language = lc ::AttrVal('global', 'language', 'DE');

    # create data for the GChart
    my $hAxis   = $FHEM::Buienradar::Translations{'GChart'}{'hAxis'}{$language};
    my $vAxis   = $FHEM::Buienradar::Translations{'GChart'}{'vAxis'}{$language};
    my $title   = sprintf(
        $FHEM::Buienradar::Translations{'GChart'}{'title'}{$language},
        $hash->{LATITUDE},
        $hash->{LONGITUDE}
    );
    my $legend  = $FHEM::Buienradar::Translations{'GChart'}{'legend'}{$language};

    return <<'CHART'
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
    my $hash = $::defs{$name};

    unless ($hash->{'.SERIALIZED'}) {
        ::Log3($name, 3,
            sprintf(
                q{[%s] Can't return serizalized data for FHEM::Buienradar::LogProxy. Using dummy data},
                $name
            )
        );

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

sub TextChart {
    my $name = shift;
    my $hash = $::defs{$name};

    unless ($hash->{'.SERIALIZED'}) {
        ::Log3($name, 3,
            sprintf(
                q{[%s] Can't return serizalized data for FHEM::Buienradar::TextChart.},
                $name
            )
        );

        # return dummy data
        return;
    }

    my %storedData = %{ Storable::thaw($hash->{'.SERIALIZED'}) };

    my $data = join '\n', map {
        my ($time, $precip, $bar) = (
            POSIX::strftime('%H:%M', localtime $storedData{$_}{'start'}),
            sprintf('% 7.3f', $storedData{$_}{'precipitation'}),
            # @todo
            (($storedData{$_}{'precipitation'} < 5) ? q{=} x  POSIX::lround(abs($storedData{$_}{'precipitation'} * 10)) : (q{=} x  50) . q{>}),
        );
        qq[$time | $precip | $bar]
    } sort keys %storedData;

    return $data;
}

sub ParseHttpResponse {
    my ( $param, $err, $data ) = @_;
    my $hash = $param->{hash};
    my $name = $hash->{NAME};
    $hash->{'.RainStart'} = undef;

    #Debugging('*** RESULT ***');
    #Debugging(Dumper {param => $param, data => $data, error => $err});

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

            Debugging({msg => 'HTTP Response code is: ' . $param->{'code'}});

            if ($param->{'code'} eq '404') {
                my $response_body;
                $response_body = eval { $response_body = from_json($data) } unless @errors;

                unless ($@) {
                    Debugging(Dumper {body => $response_body});
                    $error = qq[Location is not in coverage for region '$hash->{REGION}'];
                }
            }

            ::Log3($name, 1, qq{[$name] $error'});
            ::Log3($name, 3, qq{[$name] } . Dumper($param));
            ::readingsSingleUpdate($hash, 'state', $error, 1);
            ResetResult($hash);
            return;
        }

        $forecast_data = eval { $forecast_data = from_json($data) } unless @errors;

        if ($@) {
            $error = sprintf(
                q[Can't evaluate JSON from %s: %s],
                $hash->{URL},
                $@
            );
            ::Log3($name, 1, '[$name] $error');
            ::Log3($name, 3, '[$name] ' . join(q{}, map { qq{[$name] $_} } Dumper($data))) if ::AttrVal('global', 'stacktrace', 0) == 1;
            ::readingsSingleUpdate($hash, 'state', $error, 1);
            ResetResult($hash);
            return;
        }

        unless ($forecast_data->{'success'}) {
            $error = 'Got JSON but buienradar.nl has some troubles delivering meaningful data!';
            ::Log3($name, 1, '[$name] $error');
            ::Log3($name, 3, '[$name] ' . join(q{}, map { qq{[$name] $_} } Dumper($data))) if ::AttrVal('global', 'stacktrace', 0) == 1;
            ::readingsSingleUpdate($hash, 'state', $error, 1);
            ResetResult($hash);
            return;
        }

        my @precip;
        @precip = @{$forecast_data->{'precip'}} unless @errors;

        ::Log3($name, 3, sprintf(
            q{[%s] Parsed the following data from the buienradar JSON:\n%s},
            $name, join(q{}, map { qq{[$name] $_} } Dumper(@precip))
        )) if ::AttrVal('global', 'stacktrace', 0) == 1;

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
    local $OFS = '\n';
    ::Debug("@_") if ::AttrVal('global', 'verbose', undef) == 3 or ::AttrVal($device, 'debug', 0) eq '1';
    return;
}

1;

=pod

=over 1

=item helper

=item summary Precipitation forecasts based on buienradar.nl

=item summary_DE Niederschlagsvorhersage auf Basis des Wetterdienstes buienradar.nl

=back

=begin html

=end html

=begin html_DE


=end html_DE

=cut

=for :application/json;q=META.json 59_Buienradar.pm

=end :application/json;q=META.json
