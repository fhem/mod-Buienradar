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

=pod

=encoding UTF-8

=begin html

<p><a name="Buienradar" id="Buienradar"></a></p>
<h2>Buienradar</h2>
<p>Buienradar provides access to precipitation forecasts by the dutch service <a href="https://www.buienradar.nl">Buienradar.nl</a>.</p>
<p><span id="Buienradardependecies"></span></p>
<h3>Dependencies</h3>
<p>Buienradar depends on the following minimal versions or CPAN-Modules, <abbr>resp.</abbr></p>
<ul>
  <li>Perl ≥ 5.13.9</li>
  <li>
    <a href="https://metacpan.org/pod/Readonly">Readonly</a>
  </li>
  <li>
    <a href="https://metacpan.org/pod/JSON::MaybeXS">JSON::MaybeXS</a>
  </li>
</ul>
<p>Recommended is:</p>
<ul>
  <li>
    <a href="https://metacpan.org/pod/Cpanel::JSON::XS">Cpanel::JSON::XS</a>
  </li>
</ul>
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
<pre><code>    { FHEM::Buienradar::chart_html_bar("buienradar device name")}

can be retrieved.</code></pre>
<ul>
  <li>
    <p>A chart generated by Google Charts in <abbr>PNG</abbr> format, which can be viewed with</p>
    <pre><code>  { FHEM::Buienradar::chart_gchart("buienradar device name")}</code></pre>
    <p>can be retrieved. <strong>Caution!</strong> Please note that data is transferred to Google for this purpose!</p>
  </li>
  <li>
    <p><abbr>FTUI</abbr> is supported by the LogProxy format:</p>
    <pre><code>  { FHEM::Buienradar::logproxy_wrapper("buienradar device name")}</code></pre>
  </li>
  <li>
    <p>A plain text representation can be displayed with</p>
    <pre><code>  { FHEM::Buienradar::chart_textbar(q{buienradar device name}, q{bar chart character})}</code></pre>
    <p>The bar chart character is optional and defaults to <code>=</code>.</p>
    <p>Every line represents a record of the whole set, i.e. if called by</p>
    <pre><code>  { FHEM::Buienradar::chart_textbar(q{buienradar_test_device}, q{#})}</code></pre>
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
<p>Buienradar benötigt folgende CPAN-Module <abbr>bzw.</abbr> Versionen:</p>
<ul>
  <li>Perl ≥ 5.13.9</li>
  <li>
    <a href="https://metacpan.org/pod/Readonly">Readonly</a>
  </li>
  <li>
    <a href="https://metacpan.org/pod/JSON::MaybeXS">JSON::MaybeXS</a>
  </li>
</ul>
<p>Empfohlen wird:</p>
<ul>
  <li>
    <a href="https://metacpan.org/pod/Cpanel::JSON::XS">Cpanel::JSON::XS</a>
  </li>
</ul>
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
<pre><code>    { FHEM::Buienradar::chart_html_bar``("name des buienradar device")}
    
abgerufen werden.</code></pre>
<ul>
  <li>
    <p>Ein von Google Charts generiertes Diagramm im <abbr>PNG</abbr>-Format, welcher mit</p>
    <pre><code>  { FHEM::Buienradar::chart_gchart("name des buienradar device")}</code></pre>
    <p>abgerufen werden kann. <strong>Achtung!</strong> Dazu werden Daten an Google übertragen!</p>
  </li>
  <li>
    <p>Für <abbr>FTUI</abbr> werden die Daten im LogProxy-Format bereitgestellt:</p>
    <pre><code>  { FHEM::Buienradar::logproxy_wrapper("name des buienradar device")}</code></pre>
  </li>
  <li>
    <p>Für eine reine Text-Ausgabe der Daten als Graph, kann</p>
    <pre><code>  { FHEM::Buienradar::chart_textbar(q{name des buienradar device}, q{verwendetes zeichen})}</code></pre>
    <p>verwendet werden. Das <code>verwendete zeichen</code> ist optional und mit <code>=</code> vorbelegt. Ausgegeben wird beispielsweise für den Aufruf</p>
    <pre><code>  { FHEM::Buienradar::chart_textbar(q{buienradar_test}, q{#}) }</code></pre>
    <p>für jeden Datensatz eine Zeile im Muster</p>
    <pre><code>  22:25 |   0.060 | #
  22:30 |   0.370 | ###
  22:35 |   0.650 | #######</code></pre>
    <p>wobei für jede 0.1 mm/h Niederschlag das <code>#</code> verwendet wird, maximal jedoch 50 Einheiten. Mehr werden mit einem <code>&gt;</code> abgekürzt.</p>
    <pre><code>  23:00 |  11.800 | ##################################################&gt;</code></pre>
  </li>
</ul>

=end html_DE

=for :application/json;q=META.json

=end :application/json;q=META.json

=cut

1;