<span id="Buienradar" />

## Buienradar
Das Buienradar-Modul bindet die Niederschlagsvorhersagedaten der freien <abbr title="Application Program Interface">API</abbr> 
von [Buienradar.nl](https://www.buienradar.nl) an.

<span id="Buienradardefine"></span>
### Define
    define <devicename> Buienradar [latitude] [longitude]

Die Werte für latitude und longitude sind optional und werden, wenn nicht explizit angegeben, von <var>global</var> bezogen.
Die minimalste Definition lautet demnach:

    define <devicename> Buienradar
  
<span id="Buienradarget" />  

### Get
Aktuell lassen sich folgende Daten mit einem Get-Aufruf beziehen:

* ``rainDuration``  - Die voraussichtliche Dauer des n&auml;chsten Niederschlags in Minuten.
* ``startse``       - Der n&auml;chste Niederschlag beginnt in <var>n</var> Minuten. **Obsolet!**
* ``refresh``       - Neue Daten abfragen.
* ``version``       - Aktuelle Version abfragen.
* ``testVal``       - Rechnet einen Buienradar-Wert zu Testzwecken in mm/m² um. Dies war für die alte <abbr>API</abbr> von Buienradar.nl nötig. **Obsolet!**

<span id="Buienradarreadings" />  

### Readings
Aktuell liefert Buienradar folgende Readings:
* ``Begin``         - Beginn des nächsten Niederschlag in HH:MM format. Wenn kein Niederschlag gemeldet ist, <var>unknown</var>.
* ``Duration``      - Zeitliche Dauer der gelieferten Niederschlagsdaten in HH:MM Format.
* ``End``           - Ende des nächsten Niederschlag in HH:MM format. Wenn kein Niederschlag gemeldet ist, <var>unknown</var>.
* ``rainAmount``    - Menge des gemeldeten Niederschlags in mm/h (= l/qm) für die nächste Stunde.
* ``rainBegin``     - Beginn des nächsten Niederschlag. Wenn kein Niederschlag gemeldet ist, <var>unknown</var>.
* ``raindEnd``      - Ende des nächsten Niederschlag. Wenn kein Niederschlag gemeldet ist, <var>unknown</var>.
* ``rainDataStart`` - Zeitlicher Beginn der gelieferten Niederschlagsdaten.
* ``rainDataEnd``   - Zeitliches Ende der gelieferten Niederschlagsdaten.
* ``rainLaMetric``  - Aufbereitete Daten für LaMetric-Devices.
* ``rainMax``       - Die maximale Niederschlagsmenge in mm für ein 5 Min. Intervall auf Basis der vorliegenden Daten.
* ``rainNow``       - Die vorhergesagte Niederschlagsmenge für das aktuelle 5 Min. Intervall in mm.
* ``rainTotal``     - Die gesamte vorhergesagte Niederschlagsmenge in mm.

<span id="Buienradarattr" />

### Attribute

* <a name="disabled"></a> ``disabled 1|0|on|off``   - Wenn ``disabled`` auf ``on`` oder ``1`` gesetzt wird, wird das Device keine weiteren Anfragen mehr an Buienradar.nl durchführen. ``off`` oder ``0`` reaktiviert das Modul, ebenso wenn das Attribut gelöscht wird.
* <a name="region"></a> ``region nl|de`` - Erlaubte Werte sind ``nl`` (Standardwert) und ``de``. In einigen Fällen, insbesondere im Süden und Osten Deutschlands, liefert ``de`` überhaupt Werte.
* <a name="interval"></a>  ``interval 10|60|120|180|240|300|600`` - Aktualisierung der Daten alle <var>n</var> Sekunden. **Achtung!** 10 Sekunden ist ein sehr aggressiver Wert und sollte mit Bedacht gewählt werden, <abbr>z.B.</abbr> bei der Fehlersuche. Standardwert sind 120 Sekunden. 

### Visualisierungen
Buienradar bietet neben der üblichen Ansicht als Device auch die Möglichkeit, die Daten als Charts in verschiedenen Formaten zu visualisieren.
* Eine HTML-Version die in der Detailansicht standardmäßig eingeblendet wird und mit
        
        { FHEM::Buienradar::HTML("name des buienradar device")}
        
    abgerufen werden kann.
* Eine HTML-"BAR"-Version, diese gibt einen HTML Balken mit einer farblichen Representation der Regenmenge aus und kann mit
        
        { FHEM::Buienradar::BAR("name des buienradar device")}
        
    abgerufen werden.
* Ein von Google Charts generiertes Diagramm im <abbr>PNG</abbr>-Format, welcher mit

        { FHEM::Buienradar::GChart("name des buienradar device")}
        
    abgerufen werden kann. **Achtung!** Dazu werden Daten an Google übertragen!
    
* Für <abbr>FTUI</abbr> werden die Daten im LogProxy-Format bereitgestellt:

        { FHEM::Buienradar::LogProxy("name des buienradar device")}
