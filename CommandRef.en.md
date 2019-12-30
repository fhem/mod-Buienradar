<span id="Buienradar" />

## Buienradar
Buienradar provides access to precipitation forecasts by the dutch service [Buienradar.nl](https://www.buienradar.nl).

<span id="Buienradardefine"></span>
### Define
    define <devicename> Buienradar [latitude] [longitude]

<var>latitude</var> and <var>longitude</var> are facultative and will gathered from <var>global</var> if not set.
So the smallest possible definition is:

    define <devicename> Buienradar
  
<span id="Buienradarset" />  

### Set
<var>Set</var> will get you the following:

* ``refresh``       - get new data from Buienradar.nl.

<span id="Buienradarget" />  

### Get
<var>Get</var> will get you the following:

* ``rainDuration``  - predicted duration of the next precipitation in minutes.
* ``startsIn``      - next precipitation starts in <var>n</var> minutes. **Obsolete!**
* ``version``       - get current version of the Buienradar module.

<span id="Buienradarreadings" />  

### Readings
Buienradar provides several readings:
* ``rainAmount``            - amount of predicted precipitation in mm/h for the next 5 minute interval.
* ``rainBegin``             - starting time of the next precipitation, <var>unknown</var> if no precipitation is predicted.
* ``raindEnd``              - ending time of the next precipitation, <var>unknown</var> if no precipitation is predicted.
* ``rainDataStart``         - starting time of gathered data.
* ``rainDataEnd``           - ending time of gathered data.
* ``rainLaMetric``          - data formatted for a LaMetric device.
* ``rainMax``               - maximal amount of precipitation for **any** 5 minute interval of the gathered data in mm/h.
* ``rainNow``               - amount of precipitation for the **current** 5 minute interval in mm/h.
* ``rainTotal``             - total amount of precipition for the gathered data in mm/h.
* ``rainDuration``          - duration of the precipitation contained in the forecast
* ``rainDurationTime``      - duration of the precipitation contained in the forecast in HH:MM
* ``rainDurationIntervals`` - amount of intervals with precipitation
* ``rainDurationPercent``   - percentage of interavls with precipitation

<span id="Buienradarattr" />

### Attributes
* <a name="disabled"></a> ``disabled on|off``   - If ``disabled`` is set to `on`, no further requests to Buienradar.nl will be performed. ``off`` reactivates the device, also if the attribute ist simply deleted.
* <a name="region"></a> ``region nl|de`` - Allowed values are ``nl`` (default value) and ``de``. In some cases, especially in the south and east of Germany, ``de`` returns values at all.
* <a name="interval"></a> ``interval 10|60|120|180|240|300`` - Data update every <var>n</var> seconds. **Attention!** 10 seconds is a very aggressive value and should be chosen carefully,  <abbr>e.g.</abbr> when troubleshooting. The default value is 120 seconds.  

### Visualisation
Buienradar offers besides the usual view as device also the possibility to visualize the data as charts in different formats.
* An HTML version that is displayed in the detail view by default and can be viewed with 
    
        { FHEM::Buienradar::HTML("buienradar device name")}

    can be retrieved.
    
* A chart generated by Google Charts in <abbr>PNG</abbr> format, which can be viewed with

        { FHEM::Buienradar::GChart("buienradar device name")}
        
    can be retrieved. **Caution!** Please note that data is transferred to Google for this purpose!
    
* <abbr>FTUI</abbr> is supported by the  LogProxy format:

        { FHEM::Buienradar::LogProxy("buienradar device name")}
        
* A plain text representation can be display by

        { FHEM::Buienradar::TextChart("buienradar device name")}
        
    Every line represents a record of the whole set in a format like
    
        22:25 |   0.060 | =
        22:30 |   0.370 | ====
        22:35 |   0.650 | =======
        
    For every 0.1 mm/h precipitation a ``=`` is displayed, but the output is capped to 50 units. If more than 50 units
    would be display, the bar is appended with a ``>``.
    
        23:00 |  11.800 | ==================================================>