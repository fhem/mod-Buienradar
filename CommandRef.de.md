<a name="Buienradar" />

## Buienradar
Das Buienradar-Modul bindet die Niederschlagsvorhersagedaten der freien <abbr title="Application Program Interface">API</abbr> 
von [Buienradar.nl](https://www.buienradar.nl) an.

Buienradar benötigt folgende CPAN-Module <abbr>bzw.</abbr> Versionen:

* Perl ≥ 5.13.9
* [Readonly](https://metacpan.org/pod/Readonly)
* [JSON::MaybeXS](https://metacpan.org/pod/JSON::MaybeXS)

Empfohlen wird:

* [Cpanel::JSON::XS](https://metacpan.org/pod/Cpanel::JSON::XS)

<span id="Buienradardefine"></span>
### Define
    define <devicename> Buienradar [latitude] [longitude]

Die Werte für latitude und longitude sind optional und werden, wenn nicht explizit angegeben, von <var>global</var> bezogen.
Die minimalste Definition lautet demnach:

    define <devicename> Buienradar
  
<span id="Buienradarset" />  

### Set 
Folgende Set-Aufrufe werden unterstützt:

* ``refresh``       - Neue Daten abfragen.

<span id="Buienradarget" />  

### Get
Aktuell lassen sich folgende Daten mit einem Get-Aufruf beziehen:

* ``rainDuration``  - Die voraussichtliche Dauer des n&auml;chsten Niederschlags in Minuten.
* ``startsIn``      - Der n&auml;chste Niederschlag beginnt in <var>n</var> Minuten. **Obsolet!**
* ``version``       - Aktuelle Version abfragen.

<span id="Buienradarreadings" />  

### Readings
Aktuell liefert Buienradar folgende Readings:

* ``rainAmount``            - Menge des gemeldeten Niederschlags in mm/h für den nächsten 5-Minuten-Intervall.

* ``rainBegin``             - Beginn des nächsten Niederschlag. Wenn kein Niederschlag gemeldet ist, <var>unknown</var>.

* ``raindEnd``              - Ende des nächsten Niederschlag. Wenn kein Niederschlag gemeldet ist, <var>unknown</var>.

* ``rainDataStart``         - Zeitlicher Beginn der gelieferten Niederschlagsdaten.

* ``rainDataEnd``           - Zeitliches Ende der gelieferten Niederschlagsdaten.

* ``rainLaMetric``          - Aufbereitete Daten für LaMetric-Devices.

* ``rainMax``               - Die maximale Niederschlagsmenge in mm/h für ein 5 Min. Intervall auf Basis der vorliegenden Daten.

* ``rainNow``               - Die vorhergesagte Niederschlagsmenge für das aktuelle 5 Min. Intervall in mm/h.

* ``rainTotal``             - Die gesamte vorhergesagte Niederschlagsmenge in mm/h

* ``rainDuration``          - Dauer der gemeldeten Niederschläge in Minuten

* ``rainDurationTime``      - Dauer der gemeldeten Niederschläge in HH:MM

* ``rainDurationIntervals`` - Anzahl der Intervalle mit gemeldeten Niederschlägen

* ``rainDurationPercent``   - Prozentualer Anteil der Intervalle mit Niederschlägen

<span id="Buienradarattr" />

### Attribute

* <a name="disabled"></a> ``disabled on|off``   - Wenn ``disabled`` auf `on` gesetzt wird, wird das Device keine weiteren Anfragen mehr an Buienradar.nl durchführen. ``off`` reaktiviert das Modul, ebenso wenn das Attribut gelöscht wird.

    **Achtung!** Aus Kompatibilitätsgründen zu `FHEM::IsDisabled()` wird bei einem Aufruf von `disabled` auch `disable` als weiteres Attribut gesetzt. Wird `disable` gesetzt oder gelöscht, beeinflusst
        dies `disabled` nicht! _`disable` sollte nicht verwendet werden!_

* <a name="region"></a> ``region nl|de`` - Erlaubte Werte sind ``nl`` (Standardwert) und ``de``. In einigen Fällen, insbesondere im Süden und Osten Deutschlands, liefert ``de`` überhaupt Werte.

* <a name="interval"></a>  ``interval 10|60|120|180|240|300`` - Aktualisierung der Daten alle <var>n</var> Sekunden. **Achtung!** 10 Sekunden ist ein sehr aggressiver Wert und sollte mit Bedacht gewählt werden, <abbr>z.B.</abbr> bei der Fehlersuche. Standardwert sind 120 Sekunden. 

### Visualisierungen
Buienradar bietet neben der üblichen Ansicht als Device auch die Möglichkeit, die Daten als Charts in verschiedenen Formaten zu visualisieren.
* Eine HTML-Version die in der Detailansicht standardmäßig eingeblendet wird und mit 
        
        { FHEM::Buienradar::HTML("name des buienradar device")}
        
    abgerufen werden.
* Ein von Google Charts generiertes Diagramm im <abbr>PNG</abbr>-Format, welcher mit

        { FHEM::Buienradar::GChart("name des buienradar device")}
        
    abgerufen werden kann. **Achtung!** Dazu werden Daten an Google übertragen!
    
* Für <abbr>FTUI</abbr> werden die Daten im LogProxy-Format bereitgestellt:

        { FHEM::Buienradar::logproxy_wrapper("name des buienradar device")}
        
* Für eine reine Text-Ausgabe der Daten als Graph, kann

        { FHEM::Buienradar::chart_textbar(q{name des buienradar device}, q{verwendetes zeichen})}
        
    verwendet werden. Das `verwendete zeichen` ist optional und mit `=` vorbelegt. Ausgegeben wird beispielsweise für den Aufruf
    
        { FHEM::Buienradar::chart_textbar(q{buienradar_test}, q{#}) }
        
     für jeden Datensatz eine Zeile im Muster
    
        22:25 |   0.060 | #
        22:30 |   0.370 | ###
        22:35 |   0.650 | #######
        
    wobei für jede 0.1 mm/h Niederschlag das `#` verwendet wird, maximal jedoch 50 Einheiten.
    Mehr werden mit einem `>` abgekürzt.
    
        23:00 |  11.800 | ##################################################>