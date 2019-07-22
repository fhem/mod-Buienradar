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


package main;

use strict;
use warnings;
use HttpUtils;
use DateTime;
use JSON;
use List::Util;
use Time::Seconds;
use POSIX;
use Data::Dumper;

our $device;

#####################################
sub Buienradar_Initialize($) {

    my ($hash) = @_;

    $hash->{DefFn}       = "Buienradar_Define";
    $hash->{UndefFn}     = "Buienradar_Undef";
    $hash->{GetFn}       = "Buienradar_Get";
    $hash->{FW_detailFn} = "Buienradar_detailFn";
    $hash->{AttrList}    = $readingFnAttributes;
    $hash->{".rainData"} = "";
    $hash->{".PNG"} = "";
    $hash->{REGION} = 'de';
}

sub Buienradar_detailFn($$$$) {
    my ( $FW_wname, $d, $room, $pageHash ) =
      @_;    # pageHash is set for summaryFn.
    my $hash = $defs{$d};

    return if ( !defined( $hash->{URL} ) );

    return
        Buienradar_HTML( $hash->{NAME} )
      . "<br><a href="
      . $hash->{URL}
      . " target=_blank>open data in new window</a><br>";
}

#####################################
sub Buienradar_Undef($$) {

    my ( $hash, $arg ) = @_;

    RemoveInternalTimer( $hash, "Buienradar_Timer" );
    return undef;
}

sub Buienradar_TimeCalc($$) {

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
sub Buienradar_Get($$@) {

    my ( $hash, $name, $opt, @args ) = @_;

    return "\"get $name\" needs at least one argument" unless ( defined($opt) );

    if ( $opt eq "testVal" ) {

        #return  @args;
        return 10**( ( $args[0] - 109 ) / 32 );
    }
    elsif ( $opt eq "rainDuration" ) {
        my $begin = ReadingsVal( $name, "rainBegin", "00:00" );
        my $end   = ReadingsVal( $name, "rainEnd",   "00:00" );
        if ( $begin ne $end ) {
            return Buienradar_TimeCalc( $end, $begin );
        }
        else {
            return "unknown";
        }
    }

    elsif ( $opt eq "refresh" ) {
        Buienradar_RequestUpdate($hash);
        return "";
    }
    elsif ( $opt eq "startsIn" ) {
        my $begin = ReadingsVal( $name, "rainBegin", "unknown" );
        my ( $sec, $min, $hour, $mday, $mon, $year, $wday, $yday, $isdst ) =
          localtime(time);
        my $result = "";

        if ( $begin ne "unknown" ) {

            $result = Buienradar_TimeCalc( $begin, "$hour:$min" );

            if ( $result < 0 ) {
                $result = "raining";
            }
            return $result;
        }
        return "no rain";
    }
    else {
        return
"Unknown argument $opt, choose one of testVal refresh:noArg startsIn:noArg rainDuration:noArg";
    }
}

sub Buienradar_TimeNowDiff {
   my $begin = $_[0];
   my ( $sec, $min, $hour, $mday, $mon, $year, $wday, $yday, $isdst ) = localtime(time);
   my $result = 0;
   $result = Buienradar_TimeCalc( $begin, "$hour:$min" );
   return $result;
}

#####################################
sub Buienradar_Define($$) {

    my ( $hash, $def ) = @_;

    my @a = split( "[ \t][ \t]*", $def );
    my $latitude;
    my $longitude;

    if ( ( int(@a) == 2 ) && ( AttrVal( "global", "latitude", -255 ) != -255 ) )
    {
        $latitude  = AttrVal( "global", "latitude",  51.0 );
        $longitude = AttrVal( "global", "longitude", 7.0 );
    }
    elsif ( int(@a) == 4 ) {
        $latitude  = $a[2];
        $longitude = $a[3];
    }
    else {
        return
          int(@a)
          . " <=syntax: define <name> Buienradar [<latitude> <longitude>]";
    }

    $hash->{STATE} = "Initialized";

    my $name = $a[0];
    $device = $name;

        # alle 2,5 Minuten
    my $interval = 60 * 2.5;

    $hash->{VERSION}    = "1.0";
    $hash->{INTERVAL}   = $interval;
    $hash->{LATITUDE}   = $latitude;
    $hash->{LONGITUDE}  = $longitude;
    $hash->{URL}        = undef;
    $hash->{".HTML"}    = "<DIV>";
    $hash->{READINGS}{rainBegin}{TIME} = TimeNow();
    $hash->{READINGS}{rainBegin}{VAL}  = "unknown";

    $hash->{READINGS}{rainDataStart}{TIME} = TimeNow();
    $hash->{READINGS}{rainDataStart}{VAL}  = "unknown";

    $hash->{READINGS}{rainNow}{TIME}    = TimeNow();
    $hash->{READINGS}{rainNow}{VAL}     = "unknown";
    $hash->{READINGS}{rainEnd}{TIME}    = TimeNow();
    $hash->{READINGS}{rainEnd}{VAL}     = "unknown";
    $hash->{READINGS}{rainAmount}{TIME} = TimeNow();
    $hash->{READINGS}{rainAmount}{VAL}  = "init";

    Buienradar_Timer($hash);

    return undef;
}

sub Buienradar_Timer($) {
    my ($hash) = @_;
    my $nextupdate = 0;
    RemoveInternalTimer( $hash, "Buienradar_Timer" );

    $nextupdate = int( time() + $hash->{INTERVAL} );
    $hash->{NEXTUPDATE} = FmtDateTime($nextupdate);
    Buienradar_RequestUpdate($hash);

    InternalTimer( $nextupdate, "Buienradar_Timer", $hash );

    return 1;
}

sub Buienradar_RequestUpdate($) {
    my ($hash) = @_;

    #   @todo: https://cdn-secure.buienalarm.nl/api/3.4/forecast.php?lat=51.6&lon=7.3&region=de&unit=mm/u
    $hash->{URL} =
      AttrVal( $hash->{NAME}, "BaseUrl", "https://cdn-secure.buienalarm.nl/api/3.4/forecast.php" )
        . "?lat="       . $hash->{LATITUDE}
        . "&lon="       . $hash->{LONGITUDE}
        . '&region='    . 'nl'
        . '&unit='      . 'mm/u';

    # $hash->{URL} =
    #     AttrVal( $hash->{NAME}, "BaseUrl", "http://gps.buienradar.nl/getrr.php" )
    #         . "?lat="
    #         . $hash->{LATITUDE} . "&lon="
    #         . $hash->{LONGITUDE};

    my $param = {
        url      => $hash->{URL},
        timeout  => 10,
        hash     => $hash,
        method   => "GET",
        callback => \&Buienradar_ParseHttpResponse
    };

    HttpUtils_NonblockingGet($param);
    Log3( $hash->{NAME}, 4, $hash->{NAME} . ": Update requested" );
}

sub Buienradar_HTML($;$) {
    my ( $name, $width ) = @_;
    my $hash = $defs{$name};
    my @values = split /:/, $hash->{".rainData"};

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

    $as_html .= ReadingsVal( $name, "rainDataStart", "unknown" ) . "<BR>";
    my $factor =
      ( $width ? $width : 700 ) / ( 1 + ReadingsVal( $name, "rainMax", "0" ) );
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

sub Buienradar_ParseHttpResponse($) {
    my ( $param, $err, $data ) = @_;
    my $hash = $param->{hash};
    my $name = $hash->{NAME};

    my %precipitation_forecast;

    if ( $err ne "" ) {
        Log3( $name, 3, "$name: error while requesting " . $param->{url} . " - $err" );
        $hash->{STATE} = "Error: " . $err . " => " . $data;
    }
    elsif ( $data ne "" ) {
        Log3( $name, 3, "$name: returned: $data" );
        
        my $forecast_data = JSON::from_json($data);
        my @precip = @{$forecast_data->{"precip"}};

        Debugging(Dumper @precip);

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

                if (!$rainNow and gmtime ~~ [$start..$end]) {
                    $rainNow    = $precip;
                }

                $precipitation_forecast{$start} = {
                    'start'        => $start,
                    'end'          => $end,
                    'precipiation' => $precip,
                };
            }

            $hash->{STATE} = sprintf( "%.3f mm/h", $rainNow );

            readingsBeginUpdate($hash);
                readingsBulkUpdate( $hash, "rainTotal", sprintf( "%.3f", $rainTotal) );
                readingsBulkUpdate( $hash, "rainAmount", sprintf( "%.3f", $rainTotal) );
                readingsBulkUpdate( $hash, "rainNow", sprintf( "%.3f mm/h", $rainNow ) );
                readingsBulkUpdate( $hash, "rainLaMetric", $rainLaMetric );
                readingsBulkUpdate( $hash, "rainDataStart", strftime "%R", localtime $dataStart);
                readingsBulkUpdate( $hash, "rainDataEnd", strftime "%R", localtime $dataEnd );
                readingsBulkUpdate( $hash, "rainMax", sprintf( "%.3f", $rainMax ) );
                readingsBulkUpdate( $hash, "rainBegin", (($rainStart) ? strftime "%R", localtime $rainStart : 'unknown'));
                readingsBulkUpdate( $hash, "rainEnd", (($rainEnd) ? strftime "%R", localtime $rainEnd : 'unknown'));
            readingsEndUpdate( $hash, 1 );
        }
    }
}

sub Debugging {
    local $OFS = ", ";
    Debug("@_") if AttrVal("global", "verbose", undef) eq "5" or AttrVal($name, "debug", 0) eq "1";
}


1;

=pod

=item helper
=item summary Rain prediction
=item summary_DE Regenvorhersage auf Basis des Wetterdienstes buienradar.nl

=begin html



=end html

=begin html_DE



=end html_DE

=cut
