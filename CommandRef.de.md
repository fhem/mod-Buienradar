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
* ``rainAmount``    - Menge des gemeldeten Niederschlags in mm/h für den nächsten 5-Minuten-Intervall.
* ``rainBegin``     - Beginn des nächsten Niederschlag. Wenn kein Niederschlag gemeldet ist, <var>unknown</var>.
* ``raindEnd``      - Ende des nächsten Niederschlag. Wenn kein Niederschlag gemeldet ist, <var>unknown</var>.
* ``rainDataStart`` - Zeitlicher Beginn der gelieferten Niederschlagsdaten.
* ``rainDataEnd``   - Zeitliches Ende der gelieferten Niederschlagsdaten.
* ``rainLaMetric``  - Aufbereitete Daten für LaMetric-Devices.
* ``rainMax``       - Die maximale Niederschlagsmenge in mm/h für ein 5 Min. Intervall auf Basis der vorliegenden Daten.
* ``rainNow``       - Die vorhergesagte Niederschlagsmenge für das aktuelle 5 Min. Intervall in mm/h.
* ``rainTotal``     - Die gesamte vorhergesagte Niederschlagsmenge in mm/h

<span id="Buienradarattr" />

### Attribute
* ``disabled on|off``   - Wenn ``disabled`` auf `on` gesetzt wird, wird das Device keine weiteren Anfragen mehr an Buienradar.nl durchführen. ``off`` reaktiviert das Modul, ebenso wenn das Attribut gelöscht wird.