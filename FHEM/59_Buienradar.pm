# This is free and unencumbered software released into the public domain.

#
#  59_Buienradar.pm
#       2018 lubeda
#       2019 ff. Christoph Morrison, <fhem@christoph-jeschke.de>

# Anyone is free to copy, modify, publish, use, compile, sell, or
# distribute this software, either in source code form or as a compiled
# binary, for any purpose, commercial or non-commercial, and by any
# means.

# In jurisdictions that recognize copyright laws, the author or authors
# of this software dedicate any and all copyright interest in the
# software to the public domain. We make this dedication for the benefit
# of the public at large and to the detriment of our heirs and
# successors. We intend this dedication to be an overt act of
# relinquishment in perpetuity of all present and future rights to this
# software under copyright law.

# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
# EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
# MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.
# IN NO EVENT SHALL THE AUTHORS BE LIABLE FOR ANY CLAIM, DAMAGES OR
# OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE,
# ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR
# OTHER DEALINGS IN THE SOFTWARE.

#  For more information, please refer to <http://unlicense.org/>

# See also https://www.buienradar.nl/overbuienradar/gratis-weerdata


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

our $device;
our $version = '2.2.0';
our $default_interval = ONE_MINUTE * 2;
our @errors;

our %Translations = (
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
            'de'    => 'Niederschlagsvorhersage für %s, %s',
            'en'    =>  'Precipitation forecast for %s, %s',
        },
        'legend' => {
            'de'    => 'Niederschlag',
            'en'    => 'Precipitation',
        },
    }
);

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
    $@ = undef;

    # try to use JSON wrapper
    #   for chance of better performance
    eval {

        # JSON preference order
        local $ENV{PERL_JSON_BACKEND} =
            'Cpanel::JSON::XS,JSON::XS,JSON::PP,JSON::backportPP'
            unless ( defined( $ENV{PERL_JSON_BACKEND} ) );

        require JSON;
        import JSON qw( decode_json encode_json );
        1;
    };

    if ($@) {
        $@ = undef;

        # In rare cases, Cpanel::JSON::XS may
        #   be installed but JSON|JSON::MaybeXS not ...
        eval {
            require Cpanel::JSON::XS;
            import Cpanel::JSON::XS qw(decode_json encode_json);
            1;
        };

        if ($@) {
            $@ = undef;

            # In rare cases, JSON::XS may
            #   be installed but JSON not ...
            eval {
                require JSON::XS;
                import JSON::XS qw(decode_json encode_json);
                1;
            };

            if ($@) {
                $@ = undef;

                # Fallback to built-in JSON which SHOULD
                #   be available since 5.014 ...
                eval {
                    require JSON::PP;
                    import JSON::PP qw(decode_json encode_json);
                    1;
                };

                if ($@) {
                    $@ = undef;

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
sub Initialize($) {

    my ($hash) = @_;

    $hash->{DefFn}       = "FHEM::Buienradar::Define";
    $hash->{UndefFn}     = "FHEM::Buienradar::Undefine";
    $hash->{GetFn}       = "FHEM::Buienradar::Get";
    $hash->{AttrFn}      = "FHEM::Buienradar::Attr";
    $hash->{FW_detailFn} = "FHEM::Buienradar::Detail";
    $hash->{AttrList}    = join(' ',
        (
            'disabled:on,off',
            'region:nl,de',
            'interval:10,60,120,180,240,300'
        )
    ) . " $::readingFnAttributes";
    $hash->{".PNG"} = "";
    $hash->{REGION} = 'de';
}

sub Detail($$$$) {
    my ( $FW_wname, $d, $room, $pageHash ) =
      @_;    # pageHash is set for summaryFn.
    my $hash = $::defs{$d};

    return if ( !defined( $hash->{URL} ) );

    if (::ReadingsVal($hash->{NAME}, "rainData", "unknown") ne "unknown") {
        return
            HTML($hash->{NAME})
                . "<p><a href="
                . $hash->{URL}
                . " target=_blank>Raw JSON data (new window)</a></p>"
    } else {
        return "<div><a href='$hash->{URL}'>Raw JSON data (new window)</a></div>";
    }
}

#####################################
sub Undefine($$) {

    my ( $hash, $arg ) = @_;

    ::RemoveInternalTimer( $hash, "FHEM::Buienradar::Timer" );
    return undef;
}

sub TimeCalc($$) {

    # TimeA - TimeB
    my ( $timeA, $timeB ) = @_;

    my @AtimeA = split /:/, $timeA;
    my @AtimeB = split /:/, $timeB;

    if ( $AtimeA[0] < $AtimeB[0] ) {
        $AtimeA[0] += 24;
    }

    if ( ( $AtimeA[1] < $AtimeB[1] ) && ( $AtimeA[0] != $AtimeB[0] ) ) {
        $AtimeA[1] += 60;
    }

    my $result = ( $AtimeA[0] - $AtimeB[0] ) * 60 + $AtimeA[1] - $AtimeB[1];

    return int($result);
}

###################################
sub Get($$@) {

    my ( $hash, $name, $opt, @args ) = @_;

    return "\"get $name\" needs at least one argument" unless ( defined($opt) );

    given($opt) {
        when ("version") {
            return $version;
        }
    }

    if ( $opt eq "testVal" ) {

        #return  @args;
        return 10**( ( $args[0] - 109 ) / 32 );
    }
    elsif ( $opt eq "rainDuration" ) {
        my $begin = ::ReadingsVal( $name, "rainBegin", "00:00" );
        my $end   = ::ReadingsVal( $name, "rainEnd",   "00:00" );
        if ( $begin ne $end ) {
            return TimeCalc( $end, $begin );
        }
        else {
            return "unknown";
        }
    }

    elsif ( $opt eq "refresh" ) {
        RequestUpdate($hash);
        return "";
    }
    elsif ( $opt eq "startsIn" ) {
        my $begin = ::ReadingsVal( $name, "rainBegin", "unknown" );
        my ( $sec, $min, $hour, $mday, $mon, $year, $wday, $yday, $isdst ) =
          localtime(time);
        my $result = "";

        if ( $begin ne "unknown" ) {

            $result = TimeCalc( $begin, "$hour:$min" );

            if ( $result < 0 ) {
                $result = "raining";
            }
            return $result;
        }
        return "no rain";
    }
    else {
        return
"Unknown argument $opt, choose one of version:noArg testVal refresh:noArg startsIn:noArg rainDuration:noArg";
    }
}

sub Attr {
    my ($command, $device_name, $attribute_name, $attribute_value) = @_;
    my $hash = $::defs{$device_name};

    Debugging(
        "Attr called", "\n",
        Dumper (
            $command, $device_name, $attribute_name, $attribute_value
        )
    );

    given ($attribute_name) {
        when ('disabled') {
            Debugging(
                Dumper (
                    {
                        'attribute_value' => $attribute_value,
                        'attr' => 'disabled',
                        "command" => $command,
                    }
                )
            );

            return "${attribute_value} is no valid value for disabled. Only 'on' or 'off' are allowed!"
                if $attribute_value !~ /^(on|off)$/;

            given ($command) {
                when ('set') {
                    if ($attribute_value eq "on") {
                        ::RemoveInternalTimer( $hash, "FHEM::Buienradar::Timer" );
                        $hash->{NEXTUPDATE} = undef;
                        return undef;
                    }

                    if ($attribute_value eq "off") {
                        Timer($hash);
                        return undef;
                    }
                }

                when ('del') {
                    Timer($hash) if $attribute_value eq "off";
                }
            }
        }

        when ('region') {
            return "${attribute_value} is no valid value for region. Only 'de' or 'nl' are allowed!"
                if $attribute_value !~ /^(de|nl)$/ and $command eq "set";

            given ($command) {
                when ("set") {
                    $hash->{REGION} = $attribute_value;
                }

                when ("del") {
                    $hash->{REGION} = "nl";
                }
            }

            RequestUpdate($hash);
            return undef;
        }

        when ("interval") {
            return "${attribute_value} is no valid value for interval. Only 10, 60, 120, 180, 240 or 300 are allowed!"
                if $attribute_value !~ /^(10|60|120|180|240|300)$/ and $command eq "set";

            given ($command) {
                when ("set") {
                    $hash->{INTERVAL} = $attribute_value;
                }

                when ("del") {
                    $hash->{INTERVAL} = $FHEM::Buienradar::default_interval;
                }
            }

            Timer($hash);
            return undef;
        }

    }
}

sub TimeNowDiff {
   my $begin = $_[0];
   my ( $sec, $min, $hour, $mday, $mon, $year, $wday, $yday, $isdst ) = localtime(time);
   my $result = 0;
   $result = TimeCalc( $begin, "$hour:$min" );
   return $result;
}

#####################################
sub Define($$) {

    my ( $hash, $def ) = @_;

    my @a = split( "[ \t][ \t]*", $def );
    my $latitude;
    my $longitude;

    if ( ( int(@a) == 2 ) && ( ::AttrVal( "global", "latitude", -255 ) != -255 ) )
    {
        $latitude  = ::AttrVal( "global", "latitude",  51.0 );
        $longitude = ::AttrVal( "global", "longitude", 7.0 );
    }
    elsif ( int(@a) == 4 ) {
        $latitude  = $a[2];
        $longitude = $a[3];
    }
    else {
        return
          int(@a)
          . " Syntax: define <name> Buienradar [<latitude> <longitude>]";
    }

    ::readingsSingleUpdate($hash, 'state', 'Initialized', 1);

    my $name = $a[0];
    $device = $name;


    $hash->{VERSION}    = $version;
    $hash->{INTERVAL}   = $FHEM::Buienradar::default_interval;
    $hash->{LATITUDE}   = $latitude;
    $hash->{LONGITUDE}  = $longitude;
    $hash->{URL}        = undef;
    $hash->{".HTML"}    = "<DIV>";

    ::readingsBeginUpdate($hash);
        ::readingsBulkUpdate( $hash, "rainNow", "unknown" );
        ::readingsBulkUpdate( $hash, "rainDataStart", "unknown");
        ::readingsBulkUpdate( $hash, "rainBegin", "unknown");
        ::readingsBulkUpdate( $hash, "rainEnd", "unknown");
    ::readingsEndUpdate( $hash, 1 );

    # set default region nl
    ::CommandAttr(undef, $name . ' region nl')
        unless (::AttrVal($name, 'region', undef));

    ::CommandAttr(undef, $name . ' interval ' . $FHEM::Buienradar::default_interval)
        unless (::AttrVal($name, 'interval', undef));

    Timer($hash);

    return undef;
}

sub Timer($) {
    my ($hash) = @_;
    my $nextupdate = 0;

    ::RemoveInternalTimer( $hash, "FHEM::Buienradar::Timer" );

    $nextupdate = int( time() + $hash->{INTERVAL} );
    $hash->{NEXTUPDATE} = ::FmtDateTime($nextupdate);
    RequestUpdate($hash);

    ::InternalTimer( $nextupdate, "FHEM::Buienradar::Timer", $hash );

    return 1;
}

sub RequestUpdate($) {
    my ($hash) = @_;
    my $region = $hash->{REGION};

    $hash->{URL} =
      ::AttrVal( $hash->{NAME}, "BaseUrl", "https://cdn-secure.buienalarm.nl/api/3.4/forecast.php" )
        . "?lat="       . $hash->{LATITUDE}
        . "&lon="       . $hash->{LONGITUDE}
        . '&region='    . $region
        . '&unit='      . 'mm/u';

    my $param = {
        url      => $hash->{URL},
        timeout  => 10,
        hash     => $hash,
        method   => "GET",
        callback => \&ParseHttpResponse
    };

    ::HttpUtils_NonblockingGet($param);
    ::Log3( $hash->{NAME}, 4, $hash->{NAME} . ": Update requested" );
}

sub HTML($;$) {
    my ( $name, $width ) = @_;
    my $hash = $::defs{$name};
    my @values = split /:/, ::ReadingsVal($name, "rainData", '0:0');

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
<div class="BRchart">
END_MESSAGE

    $as_html .= "<BR>Niederschlag (<a href=./fhem?detail=$name>$name</a>)<BR>";

    $as_html .= ::ReadingsVal( $name, "rainDataStart", "unknown" ) . "<BR>";
    my $factor =
      ( $width ? $width : 700 ) / ( 1 + ::ReadingsVal( $name, "rainMax", "0" ) );
    foreach my $val (@values) {
        $as_html .=
            '<div style="width: '
          . ( int( $val * $factor ) + 30 ) . 'px;">'
          . sprintf( "%.3f", $val )
          . '</div>';
    }

    $as_html .= "</DIV><BR>";
    return ($as_html);
}

sub GChart {
    my $name = shift;
    my $hash = $::defs{$name};

    my $language = lc ::AttrVal("global", "language", "DE");

    my $hAxis   = $FHEM::Buienradar::Translations{'GChart'}{'hAxis'}{$language};
    my $vAxis   = $FHEM::Buienradar::Translations{'GChart'}{'vAxis'}{$language};
    my $title   = sprintf(
        $FHEM::Buienradar::Translations{'GChart'}{'title'}{$language},
        $hash->{LATITUDE},
        $hash->{LONGITUDE}
    );
    my $legend  = $FHEM::Buienradar::Translations{'GChart'}{'legend'}{$language};
    my $data    = ::ReadingsVal($name, "chartData", "['00:00', '0.000']");

    return <<"CHART"
<div id="chart_${name}"; style="width:100%; height:100%"></div>
<script type="text/javascript" src="https://www.gstatic.com/charts/loader.js"></script>
<script type="text/javascript">

    google.charts.load("current", {packages:["corechart"]});
    google.charts.setOnLoadCallback(drawChart);
    function drawChart() {
        var data = google.visualization.arrayToDataTable([
            ['string', '${legend}'],
            ${data}
        ]);

        var options = {
            title: "${title}",
            hAxis: {
                title: "${hAxis}",
                slantedText:true,
                slantedTextAngle: 45,
                textStyle: {
                    fontSize: 10}
            },
            vAxis: {
                minValue: 0,
                title: "${vAxis}"
            }
        };

        var my_div = document.getElementById(
            "chart_${name}");        var chart = new google.visualization.AreaChart(my_div);
        google.visualization.events.addListener(chart, 'ready', function () {
            my_div.innerHTML = '<img src="' + chart.getImageURI() + '">';
        });

        chart.draw(data, options);}
</script>

CHART
}

=item C<FHEM::Buienradar::LogProxy>

C<FHEM::Buienradar::LogProxy> returns FHEM log look-alike data from the current data for using it with
FTUI. It returns a list containing three elements:

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
                "[%s] Can't return serizalized data for FHEM::Buienradar::LogProxy. Using dummy data",
                $name
            )
        );

        # return dummy data
        return (0, 0, 0);
    }

    my %data = %{ Storable::thaw($hash->{".SERIALIZED"}) };

    return (
        join("\n", map {
            join(
                ' ', (
                    strftime('%F_%T', localtime $data{$_}{'start'}),
                    sprintf('%.3f', $data{$_}{'precipiation'})
                )
            )
        } keys %data),
        0,
        ::ReadingsVal($name, "rainMax", 0)
    );
}

sub ParseHttpResponse($) {
    my ( $param, $err, $data ) = @_;
    my $hash = $param->{hash};
    my $name = $hash->{NAME};

    #Debugging("*** RESULT ***");
    #Debugging(Dumper {param => $param, data => $data, error => $err});

    my %precipitation_forecast;

    if ( $err ne "" ) {
        # Debugging("$name: error while requesting " . $param->{url} . " - $err" );
        ::readingsSingleUpdate($hash, 'state', "Error: " . $err . " => " . $data, 1);
        ResetResult($hash);
    }
    elsif ( $data ne "" ) {
        # Debugging("$name returned: $data");
        my $forecast_data;
        my $error;

        if(defined $param->{'code'} && $param->{'code'} ne "200") {
            $error = sprintf(
                "Pulling %s returns HTTP status code %d instead of 200.",
                $hash->{URL},
                $param->{'code'}
            );
            ::Log3($name, 1, "[$name] $error");
            ::Log3($name, 3, "[$name] " . Dumper($param)) if ::AttrVal("global", "stacktrace", 0) eq "1";
            ::readingsSingleUpdate($hash, 'state', $error, 1);
            ResetResult($hash);
            return undef;
        }

        $forecast_data = eval { $forecast_data = from_json($data) } unless @errors;

        if ($@) {
            $error = sprintf(
                "Can't evaluate JSON from %s: %s",
                $hash->{URL},
                $@
            );
            ::Log3($name, 1, "[$name] $error");
            ::Log3($name, 3, "[$name] " . join("", map { "[$name] $_" } Dumper($data))) if ::AttrVal("global", "stacktrace", 0) eq "1";
            ::readingsSingleUpdate($hash, 'state', $error, 1);
            ResetResult($hash);
            return undef;
        }

        unless ($forecast_data->{'success'}) {
            $error = "Got JSON but buienradar.nl has some troubles delivering meaningful data!";
            ::Log3($name, 1, "[$name] $error");
            ::Log3($name, 3, "[$name] " . join("", map { "[$name] $_" } Dumper($data))) if ::AttrVal("global", "stacktrace", 0) eq "1";
            ::readingsSingleUpdate($hash, 'state', $error, 1);
            ResetResult($hash);
            return undef;
        }

        my @precip = @{$forecast_data->{"precip"}} unless @errors;

        ::Log3($name, 3, sprintf(
            "[%s] Parsed the following data from the buienradar JSON:\n%s",
            $name, join("", map { "[$name] $_" } Dumper(@precip))
        )) if ::AttrVal("global", "stacktrace", 0) eq "1";

        if (scalar @precip > 0) {
            my $rainLaMetric    = join(',', map {$_ * 1000} @precip[0..11]);
            my $rainTotal       = List::Util::sum @precip;
            my $rainMax         = List::Util::max @precip;
            my $rainStart       = undef;
            my $rainEnd         = undef;
            my $dataStart       = $forecast_data->{start};
            my $dataEnd         = $dataStart + (scalar @precip) * 5 * ONE_MINUTE;
            my $forecast_start  = $dataStart;
            my $rainNow         = undef;
            my $rainData        = join(':', @precip);
            my $rainAmount      = $precip[0];
            my %chartData;

            for (my $precip_index = 0; $precip_index < scalar @precip; $precip_index++) {

                my $start           = $forecast_start + $precip_index * 5 * ONE_MINUTE;
                my $end             = $start + 5 * ONE_MINUTE;
                my $precip          = $precip[$precip_index];

                # create chart data for the PNG creation
                # Google takes the data as JSON encoded time => value pairs
                $chartData{strftime '%H:%M', localtime $start}  = sprintf('%.3f', $precip);

                if (!$rainStart and $precip > 0) {
                    $rainStart  = $start;
                }

                if (!$rainEnd and $rainStart and $precip == 0) {
                    $rainEnd    = $start;
                }

                if (!$rainNow and gmtime ~~ [$start..$end]) {
                    $rainNow    = $precip;
                }

                $precipitation_forecast{$start} = {
                    'start'        => $start,
                    'end'          => $end,
                    'precipiation' => $precip,
                };
            }

            $hash->{".SERIALIZED"} = Storable::freeze(\%precipitation_forecast);

            ::readingsBeginUpdate($hash);
                ::readingsBulkUpdate( $hash, "state", sprintf( "%.3f", $rainNow ) );
                ::readingsBulkUpdate( $hash, "rainTotal", sprintf( "%.3f", $rainTotal) );
                ::readingsBulkUpdate( $hash, "rainAmount", sprintf( "%.3f", $rainAmount) );
                ::readingsBulkUpdate( $hash, "rainNow", sprintf( "%.3f", $rainNow ) );
                ::readingsBulkUpdate( $hash, "rainLaMetric", $rainLaMetric );
                ::readingsBulkUpdate( $hash, "rainDataStart", strftime "%R", localtime $dataStart);
                ::readingsBulkUpdate( $hash, "rainDataEnd", strftime "%R", localtime $dataEnd );
                ::readingsBulkUpdate( $hash, "rainMax", sprintf( "%.3f", $rainMax ) );
                ::readingsBulkUpdate( $hash, "rainBegin", (($rainStart) ? strftime "%R", localtime $rainStart : 'unknown'));
                ::readingsBulkUpdate( $hash, "rainEnd", (($rainEnd) ? strftime "%R", localtime $rainEnd : 'unknown'));
                ::readingsBulkUpdate( $hash, "rainData", $rainData);
                ::readingsBulkUpdate( $hash, "chartData", join ', ', map { my ($k, $v) = ($_, $chartData{$_}); "['$k', $v]" } sort keys %chartData);
            ::readingsEndUpdate( $hash, 1 );
        }
    }
}

sub ResetResult {
    my $hash = shift;

    $hash->{'.SERIALIZED'} = undef;

    ::readingsBeginUpdate($hash);
        ::readingsBulkUpdate( $hash, "rainTotal", "unknown" );
        ::readingsBulkUpdate( $hash, "rainAmount", "unknown" );
        ::readingsBulkUpdate( $hash, "rainNow", "unknown" );
        ::readingsBulkUpdate( $hash, "rainLaMetric", "unknown" );
        ::readingsBulkUpdate( $hash, "rainDataStart", "unknown");
        ::readingsBulkUpdate( $hash, "rainDataEnd", "unknown" );
        ::readingsBulkUpdate( $hash, "rainMax", "unknown" );
        ::readingsBulkUpdate( $hash, "rainBegin", "unknown");
        ::readingsBulkUpdate( $hash, "rainEnd", "unknown");
        ::readingsBulkUpdate( $hash, "rainData", "unknown");
    ::readingsEndUpdate( $hash, 1 );
}

sub Debugging {
    local $OFS = ", ";
    ::Debug("@_") if ::AttrVal("global", "verbose", undef) eq "4" or ::AttrVal($device, "debug", 0) eq "1";
}

1;

=pod

=item helper
=item summary Precipitation forecasts based on buienradar.nl
=item summary_DE Niederschlagsvorhersage auf Basis des Wetterdienstes buienradar.nl

=begin html

=end html

=begin html_DE

=end html_DE

=cut

=for :application/json;q=META.json 59_Buienradar.pm

=end :application/json;q=META.json
