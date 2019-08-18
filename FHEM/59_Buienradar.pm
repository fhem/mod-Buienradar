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
our $version = '2.2.5';
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
            'disabled:1,0,on,off',
            'region:nl,de',
            'interval:10,60,120,180,240,300,600'
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

            given ($command) {
                when ('set') {
                
                return "${attribute_value} is no valid value for disabled. Only 'on', '1', '0' or 'off' are allowed!"
                if $attribute_value !~ /^(on|off|0|1)$/;
                
                    if ($attribute_value =~ /(on|1)/) {
                        ::RemoveInternalTimer( $hash, "FHEM::Buienradar::Timer" );
                        $hash->{NEXTUPDATE} = undef;
                        return undef;
                    }

                    if ($attribute_value =~ /(off|0)/) {
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
            return "${attribute_value} is no valid value for interval. Only 10, 60, 120, 180, 240, 300 or 600 are allowed!"
                if $attribute_value !~ /^(10|60|120|180|240|300|600)$/ and $command eq "set";

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

=item C<FHEM::Buienradar::GChart>

C<FHEM::Buienradar::GChart> returns the precipitation data from buienradar.nl as PNG, renderd by Google Charts as
a PNG data.

=cut
sub GChart {
    my $name = shift;
    my $hash = $::defs{$name};

    unless ($hash->{'.SERIALIZED'}) {
        ::Log3($name, 3,
            sprintf(
                "[%s] Can't return serizalized data for FHEM::Buienradar::GChart.",
                $name
            )
        );

        # return dummy data
        return undef;
    }

    # read & parse stored data
    my %storedData = %{ Storable::thaw($hash->{".SERIALIZED"}) };
    my $data = join ', ', map {
        my ($k, $v) = (
            strftime('%H:%M', localtime $storedData{$_}{'start'}),
            sprintf('%.3f', $storedData{$_}{'precipiation'})
        );
        "['$k', $v]"
    } sort keys %storedData;

    # get language for language dependend legend
    my $language = lc ::AttrVal("global", "language", "DE");

    # create data for the GChart
    my $hAxis   = $FHEM::Buienradar::Translations{'GChart'}{'hAxis'}{$language};
    my $vAxis   = $FHEM::Buienradar::Translations{'GChart'}{'vAxis'}{$language};
    my $title   = sprintf(
        $FHEM::Buienradar::Translations{'GChart'}{'title'}{$language},
        $hash->{LATITUDE},
        $hash->{LONGITUDE}
    );
    my $legend  = $FHEM::Buienradar::Translations{'GChart'}{'legend'}{$language};

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
            my $rainDuration    = 0;
            my $rainDurationMin = 0;
            my $dataStart       = $forecast_data->{start};
            my $dataEnd         = $dataStart + (scalar @precip) * 5 * ONE_MINUTE;
            my $forecast_start  = $dataStart;
            my $rainNow         = undef;
            my $rainData        = join(':', @precip);
            my $rainAmount      = 0;
            my $as_htmlBarhead  = '<tr style="font-size:x-small;"}>';
            my $as_htmlBar      = "";
            my $count           = 0;

            for (my $precip_index = 0; $precip_index < scalar @precip; $precip_index++) {

                my $start           = $forecast_start + $precip_index * 5 * ONE_MINUTE;
                my $end             = $start + 5 * ONE_MINUTE;
                my $precip          = $precip[$precip_index];
                my $timestamp       = $start;
                my $a               = $precip;

              if (::time_str2num(::TimeNow()) <= $start+150) {
                
                if ( ( $count % 4 ) == 0 ) {
                    $as_htmlBarhead .= '<td style="padding-left: 0; padding-right: 0">' . substr( ::FmtDateTime($timestamp), -8, 5 ) . '</td>';
                    #$as_htmlBarhead .= '<td>' . substr( ::FmtDateTime($timestamp), -8, 5 ) . '</td>';
                }
                else {
                    $as_htmlBarhead .= '<td style="padding-left: 0; padding-right: 0">&nbsp;&nbsp;&nbsp;&nbsp;</td>';
                    #$as_htmlBarhead .= '<td>&nbsp;</td>';
                }  

                    #( $precip->{ColorAsRGB} eq "Transparent" ) ||
                if ( ( myPrecip2RGB($a) eq "Transparent" ) || ( $a == 0 ) ) {
                    $as_htmlBar .= '<td style="padding-left: 0; padding-right: 0" bgcolor="#ffffff">&nbsp;&nbsp;&nbsp;</td>';
                    #$as_htmlBar .= '<td bgcolor="#ffffff">&nbsp;</td>';
                }
                else {
                  $as_htmlBar .= '<td style="padding-left: 0; padding-right: 0" bgcolor="' . myPrecip2RGB($a) . '">&nbsp;&nbsp;&nbsp;</td>';
                  #$as_htmlBar .= '<td bgcolor="' . myPrecip2RGB($a) . '">&nbsp;</td>';
                }
                if ($count < 12) { $rainAmount = $rainAmount + $precip;}
                $count++;

                if (!$rainStart and $precip > 0) {
                    $rainStart  = $start;
                }

                if (!$rainEnd and $rainStart and $precip == 0) {
                    $rainEnd    = $start;
                } elsif ($rainStart and $precip == 0 and $precip[$precip_index-1] !=0) {
                    $rainEnd    = $start;
                } elsif ($rainStart and $precip != 0 and $precip_index == ((scalar @precip)-1)) {
                    $rainEnd    = $dataEnd;
                }

                if (!$rainNow) {
                    $rainNow    = $precip;
                }

                $precipitation_forecast{$start} = {
                    'start'        => $start,
                    'end'          => $end,
                    'precipiation' => $precip,
                };
              }
            }

            $as_htmlBar = "Niederschlagsvorhersage (<a href=./fhem?detail=$name>$name</a>)<BR><table>"
                . $as_htmlBarhead
                . "</TR><tr style='border:2pt solid black'>"
                . $as_htmlBar
                . "</tr></table>";
                $hash->{".BAR"}     = $as_htmlBar;

            $hash->{".SERIALIZED"} = Storable::freeze(\%precipitation_forecast);
            $rainDurationMin = ($rainStart && $rainEnd) ? ($rainEnd-$rainStart)/60: 'unknown';
            $rainDuration = ($rainStart && $rainEnd) ? MinToHours ($rainDurationMin): 'unknown';
           #::Log3($name, 3, "[$name] $rainEnd $rainStart $rainDurationMin $rainDuration");

            ::readingsBeginUpdate($hash);
                ::readingsBulkUpdate( $hash, "state", sprintf( "%.1f", $rainNow ) );
                ::readingsBulkUpdate( $hash, "rainTotal", sprintf( "%.1f", $rainTotal) );
                ::readingsBulkUpdate( $hash, "rainAmount", sprintf( "%.1f", $rainAmount) );
                ::readingsBulkUpdate( $hash, "rainNow", sprintf( "%.1f", $rainNow ) );
                ::readingsBulkUpdate( $hash, "rainLaMetric", $rainLaMetric );
                ::readingsBulkUpdate( $hash, "rainDataStart", strftime "%Y-%m-%d %H:%M:%S", localtime $dataStart);
                ::readingsBulkUpdate( $hash, "rainDataEnd", strftime "%Y-%m-%d %H:%M:%S", localtime $dataEnd );
                ::readingsBulkUpdate( $hash, "rainMax", sprintf( "%.1f", $rainMax ) );
                ::readingsBulkUpdate( $hash, "rainBegin", (($rainStart) ? strftime "%Y-%m-%d %H:%M:%S", localtime $rainStart : 'unknown'));
                ::readingsBulkUpdate( $hash, "rainEnd", (($rainEnd) ? strftime "%Y-%m-%d %H:%M:%S", localtime $rainEnd : 'unknown'));
                ::readingsBulkUpdate( $hash, "Begin", (($rainStart) ? strftime "%H:%M", localtime $rainStart : 'unknown'));
                ::readingsBulkUpdate( $hash, "End", (($rainEnd) ? strftime "%H:%M", localtime $rainEnd : 'unknown'));
                ::readingsBulkUpdate( $hash, "Duration", $rainDuration );
                ::readingsBulkUpdate( $hash, "rainDuration",  $rainDuration );
                ::readingsBulkUpdate( $hash, "rainDurationMin",  $rainDurationMin );
                ::readingsBulkUpdate( $hash, "rainData", $rainData);
            ::readingsEndUpdate( $hash, 1 );
        }
    }
}

sub BAR($) {
    my ($name) = @_;
    my $hash = $::defs{$name};
    return $hash->{".BAR"};
    }

sub MinToHours($) {
  my($intime) = @_;
  return sprintf("%02d:%02d",(($intime/60),$intime%60));
}

sub myPrecip2RGB($) {
  my ($precip) = @_;
  my $RGB = "Transparent";
  if ($precip   == 0) {
    $RGB = "#FFFFFF";
  } elsif ($precip < 0.25) {
    $RGB = "#F0F8FF";
  } elsif ($precip < 0.75)   {
    $RGB = "#E6E6FA";
  } elsif ($precip < 1.25) {
    $RGB = "#E4D9F1";
  } elsif ($precip < 1.75)   {
    $RGB = "#C8B3E4";
  } elsif ($precip < 2.25){
    $RGB = "#AB8FD6";
  } elsif ($precip < 2.75)  {
    $RGB = "#8E6CC7";
  } elsif ($precip < 3.25){
    $RGB = "#6E49B9";
  } elsif ($precip < 3.75)  {
    $RGB = "#4A25AA";
  } elsif ($precip < 4.25){
    $RGB = "#40218C";
  } elsif ($precip < 4.75)  {
    $RGB = "#351D6E";
  } elsif ($precip < 5.25){
    $RGB = "#2B1852";
  } elsif ($precip < 5.75)  {
    $RGB = "#201338";
  } elsif ($precip < 6.25){
    $RGB = "#160C1F";
  } elsif ($precip < 6.75)  {
    $RGB = "#060C1F";
  } else {
    $RGB = "#000000";
  }
  return $RGB;
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

<p><span id="Buienradar"></span></p>
<h2>Buienradar</h2>
<p>Buienradar provides access to precipitation forecasts by the dutch service <a href="https://www.buienradar.nl">Buienradar.nl</a>.</p>
<p><span id="Buienradardefine"></span></p>
<h3>Define</h3>
<pre><code>define &lt;devicename&gt; Buienradar [latitude] [longitude]</code></pre>
<p><var>latitude</var> and <var>longitude</var> are facultative and will gathered from <var>global</var> if not set. So the smallest possible definition is:</p>
<pre><code>define &lt;devicename&gt; Buienradar</code></pre>
<p><span id="Buienradarget"></span></p>
<h3>Get</h3>
<p><var>Get</var> will get you the following:</p>
<ul>
  <li><code>rainDuration</code> - predicted duration of the next precipitation in minutes.</li>
  <li><code>startse</code> - next precipitation starts in <var>n</var> minutes. <strong>Obsolete!</strong></li>
  <li><code>refresh</code> - get new data from Buienradar.nl.</li>
  <li><code>version</code> - get current version of the Buienradar module.</li>
  <li><code>testVal</code> - converts the gathered values from the old Buienradar <abbr>API</abbr> to mm/m². <strong>Obsolete!</strong></li>
</ul>
<p><span id="Buienradarreadings"></span></p>
<h3>Readings</h3>
<p>Buienradar provides several readings:</p>
<ul>
  <li><code>Begin</code> - Start of predicted precipitation in HH:MM format. If no precipitation is predicted, <var>unknown</var>.</li>
  <li><code>Duration</code> - Duration of predicted precipitation in HH:MM Format.</li>
  <li><code>End</code> - End of predicted precipitation in HH:MM format. If no precipitation is predicted, <var>unknown</var>.</li>
  <li><code>rainAmount</code> - amount of predicted precipitation in mm/h or l/qm for the next 1 hour interval.</li>
  <li><code>rainBegin</code> - starting time of the next precipitation, <var>unknown</var> if no precipitation is predicted.</li>
  <li><code>raindEnd</code> - ending time of the next precipitation, <var>unknown</var> if no precipitation is predicted.</li>
  <li><code>rainDataStart</code> - starting time of gathered data.</li>
  <li><code>rainDataEnd</code> - ending time of gathered data.</li>
  <li><code>rainLaMetric</code> - data formatted for a LaMetric device.</li>
  <li><code>rainMax</code> - maximal amount of precipitation for <strong>any</strong> 5 minute interval of the gathered data in mm.</li>
  <li><code>rainNow</code> - amount of precipitation for the <strong>current</strong> 5 minute interval in mm.</li>
  <li><code>rainTotal</code> - total amount of precipition for the gathered data in mm.</li>
</ul>
<p><span id="Buienradarattr"></span></p>
<h3>Attributes</h3>
<ul>
  <li>
    <a name="disabled" id="disabled"></a> <code>disabled 1|0|on|off</code> - If <code>disabled</code> is set to <code>on</code> or <code>1</code>, no further requests to Buienradar.nl will be performed. <code>off</code> or <code>0</code> reactivates the device, also if the attribute ist simply deleted.
  </li>
  <li>
    <a name="region" id="region"></a> <code>region nl|de</code> - Allowed values are <code>nl</code> (default value) and <code>de</code>. In some cases, especially in the south and east of Germany, <code>de</code> returns values at all.
  </li>
  <li>
    <a name="interval" id="interval"></a> <code>interval 10|60|120|180|240|300|600</code> - Data update every <var>n</var> seconds. <strong>Attention!</strong> 10 seconds is a very aggressive value and should be chosen carefully, <abbr>e.g.</abbr> when troubleshooting. The default value is 120 seconds.
  </li>
</ul>
<h3>Visualisation</h3>
<p>Buienradar offers besides the usual view as device also the possibility to visualize the data as charts in different formats.</p>
<ul>
  <li>
    <p>A HTML version that is displayed in the detail view by default and can be viewed with</p>
    <pre><code>  { FHEM::Buienradar::HTML("buienradar device name")}</code></pre>
    <p>can be retrieved.</p>
  </li>
  <li>
    <p>A HTML-"BAR" version, which shows a HTML bar with coulored representation of rain amout and can be viewed with</p>
    <pre><code>  { FHEM::Buienradar::BAR("buienradar device name")}</code></pre>
    <p>can be retrieved.</p>
  </li>
  <li>
    <p>A chart generated by Google Charts in <abbr>PNG</abbr> format, which can be viewed with</p>
    <pre><code>  { FHEM::Buienradar::GChart("buienradar device name")}</code></pre>
    <p>can be retrieved. <strong>Caution!</strong> Please note that data is transferred to Google for this purpose!</p>
  </li>
  <li>
    <p><abbr>FTUI</abbr> is supported by the LogProxy format:</p>
    <pre><code>  { FHEM::Buienradar::LogProxy("buienradar device name")}</code></pre>
  </li>
</ul>

=end html

=begin html_DE

<p><span id="Buienradar"></span></p>
<h2>Buienradar</h2>
<p>Das Buienradar-Modul bindet die Niederschlagsvorhersagedaten der freien <abbr title="Application Program Interface">API</abbr> von <a href="https://www.buienradar.nl">Buienradar.nl</a> an.</p>
<p><span id="Buienradardefine"></span></p>
<h3>Define</h3>
<pre><code>define &lt;devicename&gt; Buienradar [latitude] [longitude]</code></pre>
<p>Die Werte für latitude und longitude sind optional und werden, wenn nicht explizit angegeben, von <var>global</var> bezogen. Die minimalste Definition lautet demnach:</p>
<pre><code>define &lt;devicename&gt; Buienradar</code></pre>
<p><span id="Buienradarget"></span></p>
<h3>Get</h3>
<p>Aktuell lassen sich folgende Daten mit einem Get-Aufruf beziehen:</p>
<ul>
  <li><code>rainDuration</code> - Die voraussichtliche Dauer des nächsten Niederschlags in Minuten.</li>
  <li><code>startse</code> - Der nächste Niederschlag beginnt in <var>n</var> Minuten. <strong>Obsolet!</strong></li>
  <li><code>refresh</code> - Neue Daten abfragen.</li>
  <li><code>version</code> - Aktuelle Version abfragen.</li>
  <li><code>testVal</code> - Rechnet einen Buienradar-Wert zu Testzwecken in mm/m² um. Dies war für die alte <abbr>API</abbr> von Buienradar.nl nötig. <strong>Obsolet!</strong></li>
</ul>
<p><span id="Buienradarreadings"></span></p>
<h3>Readings</h3>
<p>Aktuell liefert Buienradar folgende Readings:</p>
<ul>
  <li><code>Begin</code> - Beginn des nächsten Niederschlag in HH:MM format. Wenn kein Niederschlag gemeldet ist, <var>unknown</var>.</li>
  <li><code>Duration</code> - Zeitliche Dauer der gelieferten Niederschlagsdaten in HH:MM Format.</li>
  <li><code>End</code> - Ende des nächsten Niederschlag in HH:MM format. Wenn kein Niederschlag gemeldet ist, <var>unknown</var>.</li>
  <li><code>rainAmount</code> - Menge des gemeldeten Niederschlags in mm/h (= l/qm) für die nächste Stunde.</li>
  <li><code>rainBegin</code> - Beginn des nächsten Niederschlag. Wenn kein Niederschlag gemeldet ist, <var>unknown</var>.</li>
  <li><code>raindEnd</code> - Ende des nächsten Niederschlag. Wenn kein Niederschlag gemeldet ist, <var>unknown</var>.</li>
  <li><code>rainDataStart</code> - Zeitlicher Beginn der gelieferten Niederschlagsdaten.</li>
  <li><code>rainDataEnd</code> - Zeitliches Ende der gelieferten Niederschlagsdaten.</li>
  <li><code>rainLaMetric</code> - Aufbereitete Daten für LaMetric-Devices.</li>
  <li><code>rainMax</code> - Die maximale Niederschlagsmenge in mm für ein 5 Min. Intervall auf Basis der vorliegenden Daten.</li>
  <li><code>rainNow</code> - Die vorhergesagte Niederschlagsmenge für das aktuelle 5 Min. Intervall in mm.</li>
  <li><code>rainTotal</code> - Die gesamte vorhergesagte Niederschlagsmenge in mm.</li>
</ul>
<p><span id="Buienradarattr"></span></p>
<h3>Attribute</h3>
<ul>
  <li>
    <a name="disabled" id="disabled"></a> <code>disabled 1|0|on|off</code> - Wenn <code>disabled</code> auf <code>on</code> oder <code>1</code> gesetzt wird, wird das Device keine weiteren Anfragen mehr an Buienradar.nl durchführen. <code>off</code> oder <code>0</code> reaktiviert das Modul, ebenso wenn das Attribut gelöscht wird.
  </li>
  <li>
    <a name="region" id="region"></a> <code>region nl|de</code> - Erlaubte Werte sind <code>nl</code> (Standardwert) und <code>de</code>. In einigen Fällen, insbesondere im Süden und Osten Deutschlands, liefert <code>de</code> überhaupt Werte.
  </li>
  <li>
    <a name="interval" id="interval"></a> <code>interval 10|60|120|180|240|300|600</code> - Aktualisierung der Daten alle <var>n</var> Sekunden. <strong>Achtung!</strong> 10 Sekunden ist ein sehr aggressiver Wert und sollte mit Bedacht gewählt werden, <abbr>z.B.</abbr> bei der Fehlersuche. Standardwert sind 120 Sekunden.
  </li>
</ul>
<h3>Visualisierungen</h3>
<p>Buienradar bietet neben der üblichen Ansicht als Device auch die Möglichkeit, die Daten als Charts in verschiedenen Formaten zu visualisieren.</p>
<ul>
  <li>
    <p>Eine HTML-Version die in der Detailansicht standardmäßig eingeblendet wird und mit</p>
    <pre><code>  { FHEM::Buienradar::HTML("name des buienradar device")}</code></pre>abgerufen werden kann.
  </li>
  <li>
    <p>Eine HTML-"BAR"-Version, diese gibt einen HTML Balken mit einer farblichen Representation der Regenmenge aus und kann mit</p>
    <pre><code>  { FHEM::Buienradar::BAR("name des buienradar device")}</code></pre>abgerufen werden.
  </li>
  <li>
    <p>Ein von Google Charts generiertes Diagramm im <abbr>PNG</abbr>-Format, welcher mit</p>
    <pre><code>  { FHEM::Buienradar::GChart("name des buienradar device")}</code></pre>
    <p>abgerufen werden kann. <strong>Achtung!</strong> Dazu werden Daten an Google übertragen!</p>
  </li>
  <li>
    <p>Für <abbr>FTUI</abbr> werden die Daten im LogProxy-Format bereitgestellt:</p>
    <pre><code>  { FHEM::Buienradar::LogProxy("name des buienradar device")}</code></pre>
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
    "version": "2.2.5",
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
