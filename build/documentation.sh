#!/bin/bash
#!/usr/bin/env bash

module_file="FHEM/59_Buienradar.pm"

commandref_de_source="CommandRef.de.md"

commandref_en_source="CommandRef.en.md"

meta_source="meta.json"

controls_file="$1"

changed_file="CHANGED"

formatting_style="markdown_strict"

#   +------------------------------------------------------------
#
#       Substitute the place holders in the module file with
#       the converted markdown documentation
#
#   +------------------------------------------------------------
substitute() {
    # clean up
    rm -rf .CommandRef.*

    # create german CRef
    echo "" >> .${commandref_de_source}.html
    pandoc -f${formatting_style} -t html ${commandref_de_source} | tidy -qi -w --show-body-only yes - >> .${commandref_de_source}.html
    echo "" >> .${commandref_de_source}.html
    sed -i -ne "/^=begin html_DE$/ {p; r .${commandref_de_source}.html" -e ":a; n; /^=end html_DE$/ {p; b}; ba}; p" ${module_file}

    # create english CRef
    echo "" >> .${commandref_en_source}.html
    pandoc -f${formatting_style} -t html ${commandref_en_source} | tidy -qi -w --show-body-only yes - >> .${commandref_en_source}.html
    echo "" >> .${commandref_en_source}.html
    sed -i -ne "/^=begin html$/ {p; r .${commandref_en_source}.html" -e ":a; n; /^=end html$/ {p; b}; ba}; p" ${module_file}

    # insert meta data
    sed -i -ne "/^=for :application\/json;q=META.json $(basename $module_file)}$/ {p; r ${meta_source}" -e ":a; n; /^=end :application\/json;q=META.json$/ {p; b}; ba}; p" ${module_file}

    # add created files
    git add FHEM/*.pm
    git add CommandRef.*
    git add meta.json
}
