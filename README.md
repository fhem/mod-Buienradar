# FHEM::Buienradar

## General description
``FHEM::Buienradar`` extends [FHEM](https://fhem.de/) with precipiation information, delivered by the dutch service <a href="https://buienradar.nl">Buienradar</a>.

## License
This software is public domain by the [Unlicense](https://unlicense.org/).

### Contributions
You are invited to send pull requests to the the release branch you forked from whenever you think you can contribute with some useful improvements to the module. The module maintainer will review you code and decide whether it is going to be part of the module in a future release. Please read the guidelines for [contributions to unlicensed software](https://unlicense.org/#unlicensing-contributions). A [Waiver](Waiver.md) is available.

## Branching model
* [`stable`](https://github.com/fhem/mod-Buienradar/tree/stable) contains the current stable version. 
* [`oldstable`](https://github.com/fhem/mod-Buienradar/tree/oldstable) contains the previous stable version, just for stability issues. Issues for ``oldstable`` are **not** accepted.
* [`testing`](https://github.com/fhem/mod-Buienradar/tree/stable) contains the next release version, it's considered stable also, but might contains bugs or issues. Fixed set of features.
* ``development`` does not longer exist. Further development is made in release branches below ``development/$version``.
* Branches below ``release/`` contain release branches.

## Adding Buienradar to your installation of FHEM

If a new stable version is [released](https://github.com/fhem/mod-Buienradar/releases), it will be moved from `testing` to `stable`, the previous stable version will be moved to `oldstable`. So if you want to get only the stable versions, please execute

    update add https://raw.githubusercontent.com/fhem/mod-Buienradar/stable/controls_Buienradar.txt
    
at your local FHEM installation. **This is highly recommended**.

## Community support
* The [FHEM user forum](https://forum.fhem.de/) is for general support and discussion, mostly in german, but an [english section](https://forum.fhem.de/index.php/board,52.0.html) is also available. Please read the [Posting 101](https://forum.fhem.de/index.php/topic,71806.0.html) before your first posting there. 
* `FHEM::Buienradar` specific discussions are on topic at the [Unterstützende Dienste / Wettermodule](https://forum.fhem.de/index.php/board,86.0.html) board.

## Bug reports and feature requests
Bugs and feature requests are tracked using [Github Issues](https://github.com/fhem/mod-Buienradar/issues).

## Contributors
See the [Authors](Authors.md) file for a list of contributors.