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
use GPUtils qw(GP_Import GP_Export);
use experimental qw( switch );

our $device;
our $version = '2.1.1';
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

        # alle 2,5 Minuten
    my $interval = 60 * 2.5;

    $hash->{VERSION}                    = $version;
    $hash->{INTERVAL}   = $interval;
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

    #   @todo: https://cdn-secure.buienalarm.nl/api/3.4/forecast.php?lat=51.6&lon=7.3&region=de&unit=mm/u
    $hash->{URL} =
      ::AttrVal( $hash->{NAME}, "BaseUrl", "https://cdn-secure.buienalarm.nl/api/3.4/forecast.php" )
        . "?lat="       . $hash->{LATITUDE}
        . "&lon="       . $hash->{LONGITUDE}
        . '&region='    . 'nl'
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
        ResetReadings($hash);
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
            ResetReadings($hash);
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
            ResetReadings($hash);
            return undef;
        }

        unless ($forecast_data->{'success'}) {
            $error = "Got JSON but buienradar.nl has some troubles delivering meaningful data!";
            ::Log3($name, 1, "[$name] $error");
            ::Log3($name, 3, "[$name] " . join("", map { "[$name] $_" } Dumper($data))) if ::AttrVal("global", "stacktrace", 0) eq "1";
            ::readingsSingleUpdate($hash, 'state', $error, 1);
            ResetReadings($hash);
            return undef;
        }

        my @precip = @{$forecast_data->{"precip"}} unless @errors;

        ::Log3($name, 3, sprintf(
            "[%s] Parsed the following data from the buienradar JSON:\n%s",
            $name, join("", map { "[$name] $_" } Dumper(@precip))
        )) if ::AttrVal("global", "stacktrace", 0) eq "1";

        $hash->{DATA} = join(", ", @precip);

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
            my $rainAmount      =   $precip[0];

            for (my $precip_index = 0; $precip_index < scalar @precip; $precip_index++) {
                my $start    = $forecast_start + $precip_index * 5 * ONE_MINUTE;
                my $end      = $start + 5 * ONE_MINUTE;
                my $precip   = $precip[$precip_index];

                if (!$rainStart and $precip > 0) {
                    $rainStart  = $start;
                }

                if (!$rainEnd and $rainStart and $precip == 0) {
                    $rainEnd    = $start;
                }

                if (time() ~~ [$start..$end]) {
                    $rainNow    = $precip;
                }

                $precipitation_forecast{$start} = {
                    'start'        => $start,
                    'end'          => $end,
                    'precipiation' => $precip,
                };
            }

            ::readingsBeginUpdate($hash);
                ::readingsBulkUpdate( $hash, "state", sprintf( "%.3f", $rainNow ) );
                ::readingsBulkUpdate( $hash, "rainTotal", sprintf( "%.3f", $rainTotal) );
                ::readingsBulkUpdate( $hash, "rainAmount", sprintf( "%.3f", $rainAmount) );
                ::readingsBulkUpdate( $hash, "rainNow", sprintf( "%.3f mm/h", $rainNow ) );
                ::readingsBulkUpdate( $hash, "rainLaMetric", $rainLaMetric );
                ::readingsBulkUpdate( $hash, "rainDataStart", strftime "%R", localtime $dataStart);
                ::readingsBulkUpdate( $hash, "rainDataEnd", strftime "%R", localtime $dataEnd );
                ::readingsBulkUpdate( $hash, "rainMax", sprintf( "%.3f", $rainMax ) );
                ::readingsBulkUpdate( $hash, "rainBegin", (($rainStart) ? strftime "%R", localtime $rainStart : 'unknown'));
                ::readingsBulkUpdate( $hash, "rainEnd", (($rainEnd) ? strftime "%R", localtime $rainEnd : 'unknown'));
                ::readingsBulkUpdate( $hash, "rainData", $rainData);
            ::readingsEndUpdate( $hash, 1 );
        }
    }
}

sub ResetReadings {
    my $hash = shift;

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
    local $OFS = "\n";
    ::Debug("@_") if ::AttrVal("global", "verbose", undef) eq "4" or ::AttrVal($device, "debug", 0) eq "1";
}


1;

=pod

=item helper
=item summary Precipitation forecasts based on buienradar.nl
=item summary_DE Niederschlagsvorhersage auf Basis des Wetterdienstes buienradar.nl

=begin html

<p><span id="Buienradar"></span></p>
<h2 id="buienradar">Buienradar</h2>
<p>Buienradar provides access to precipiation forecasts by the dutch service <a href="https://www.buienradar.nl">Buienradar.nl</a>.</p>
<p><span id="Buienradardefine"></span></p>
<h3 id="define">Define</h3>
<pre><code>define &lt;devicename&gt; Buienradar [latitude] [longitude]</code></pre>
<p><var>latitude</var> and <var>longitude</var> are facultative and will gathered from <var>global</var> if not set.<br>
So the smallest possible definition is:</p>
<pre><code>define &lt;devicename&gt; Buienradar</code></pre>
<p><span id="Buienradarget"></span></p>
<h3 id="get">Get</h3>
<p><var>Get</var> will get you the following:</p>
<ul>
  <li><code>rainDuration</code> - predicted duration of the next precipiation in minutes.<br></li>
  <li><code>startse</code> - next precipiation starts in <var>n</var> minutes. <strong>Obsolete!</strong><br></li>
  <li><code>refresh</code> - get new data from Buienradar.nl.<br></li>
  <li><code>version</code> - get current version of the Buienradar module.<br></li>
  <li><code>testVal</code> - converts the gathered values from the old Buienradar <abbr>API</abbr> to mm/m². <strong>Obsolete!</strong></li>
</ul>
<p><span id="Buienradarreadings"></span></p>
<h3 id="readings">Readings</h3>
<p>Buienradar provides several readings:</p>
<ul>
  <li><code>rainAmount</code> - amount of predicted precipiation in mm/h for the next 5 minute interval.<br></li>
  <li><code>rainBegin</code> - starting time of the next precipiation, <var>unknown</var> if no precipiation is predicted.<br></li>
  <li><code>raindEnd</code> - ending time of the next precipiation, <var>unknown</var> if no precipiation is predicted.<br></li>
  <li><code>rainDataStart</code> - starting time of gathered data.<br></li>
  <li><code>rainDataEnd</code> - ending time of gathered data.<br></li>
  <li><code>rainLaMetric</code> - data formatted for a LaMetric device.<br></li>
  <li><code>rainMax</code> - maximal amount of precipiation for <strong>any</strong> 5 minute interval of the gathered data in mm/h.<br></li>
  <li><code>rainNow</code> - amount of precipiation for the <strong>current</strong> 5 minute interval in mm/h.<br></li>
  <li><code>rainTotal</code> - total amount of precipition for the gathered data in mm/h.</li>
</ul>
<p><span id="Buienradarattr"></span></p>
<h3 id="attributes">Attributes</h3>
<ul>
  <li><code>disabled on|off</code> - If <code>disabled</code> is set to <code>on</code>, no further requests to Buienradar.nl will be performed. <code>off</code> reactives the module, also if the attribute ist simply deleted.</li>
</ul>

=end html

=begin html_DE

<p><span id="Buienradar"></span></p>
<h2 id="buienradar">Buienradar</h2>
<p>Das Buienradar-Modul bindet die Niederschlagsvorhersagedaten der freien <abbr title="Application Program Interface">API</abbr><br>
von <a href="https://www.buienradar.nl">Buienradar.nl</a> an.</p>
<p><span id="Buienradardefine"></span></p>
<h3 id="define">Define</h3>
<pre><code>define &lt;devicename&gt; Buienradar [latitude] [longitude]</code></pre>
<p>Die Werte für latitude und longitude sind optional und werden, wenn nicht explizit angegeben, von <var>global</var> bezogen.<br>
Die minimalste Definition lautet demnach:</p>
<pre><code>define &lt;devicename&gt; Buienradar</code></pre>
<p><span id="Buienradarget"></span></p>
<h3 id="get">Get</h3>
<p>Aktuell lassen sich folgende Daten mit einem Get-Aufruf beziehen:</p>
<ul>
  <li><code>rainDuration</code> - Die voraussichtliche Dauer des nächsten Niederschlags in Minuten.<br></li>
  <li><code>startse</code> - Der nächste Niederschlag beginnt in <var>n</var> Minuten. <strong>Obsolet!</strong><br></li>
  <li><code>refresh</code> - Neue Daten abfragen.<br></li>
  <li><code>version</code> - Aktuelle Version abfragen.<br></li>
  <li><code>testVal</code> - Rechnet einen Buienradar-Wert zu Testzwecken in mm/m² um. Dies war für die alte <abbr>API</abbr> von Buienradar.nl nötig. <strong>Obsolet!</strong></li>
</ul>
<p><span id="Buienradarreadings"></span></p>
<h3 id="readings">Readings</h3>
<p>Aktuell liefert Buienradar folgende Readings:</p>
<ul>
  <li><code>rainAmount</code> - Menge des gemeldeten Niederschlags in mm/h für den nächsten 5-Minuten-Intervall.<br></li>
  <li><code>rainBegin</code> - Beginn des nächsten Niederschlag. Wenn kein Niederschlag gemeldet ist, <var>unknown</var>.<br></li>
  <li><code>raindEnd</code> - Ende des nächsten Niederschlag. Wenn kein Niederschlag gemeldet ist, <var>unknown</var>.<br></li>
  <li><code>rainDataStart</code> - Zeitlicher Beginn der gelieferten Niederschlagsdaten.<br></li>
  <li><code>rainDataEnd</code> - Zeitliches Ende der gelieferten Niederschlagsdaten.<br></li>
  <li><code>rainLaMetric</code> - Aufbereitete Daten für LaMetric-Devices.<br></li>
  <li><code>rainMax</code> - Die maximale Niederschlagsmenge in mm/h für ein 5 Min. Intervall auf Basis der vorliegenden Daten.<br></li>
  <li><code>rainNow</code> - Die vorhergesagte Niederschlagsmenge für das aktuelle 5 Min. Intervall in mm/h.<br></li>
  <li><code>rainTotal</code> - Die gesamte vorhergesagte Niederschlagsmenge in mm/h</li>
</ul>
<p><span id="Buienradarattr"></span></p>
<h3 id="attribute">Attribute</h3>
<ul>
  <li><code>disabled on|off</code> - Wenn <code>disabled</code> auf <code>on</code> gesetzt wird, wird das Device keine weiteren Anfragen mehr an Buienradar.nl durchführen. <code>off</code> reaktiviert das Modul, ebenso wenn das Attribut gelöscht wird.</li>
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
    "version": "2.1.1",
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
