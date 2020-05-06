#!/bin/bash

module_file="FHEM/59_Buienradar.pm"

commandref_de_source="CommandRef.de.md"

commandref_en_source="CommandRef.en.md"

meta_source="meta.json"

controls_file="$1"

changed_file="CHANGED"

formatting_style="markdown_strict"

create_controlfile() {
    rm ${controls_file}
    find -type f \( -path './FHEM/*' -o -path './www/*' \) -print0 | while IFS= read -r -d '' f;
    do
        stat ${f}
        echo "DEL ${f}" >> ${controls_file}
        out="UPD "$(stat -c %y  $f | cut -d. -f1 | awk '{printf "%s_%s",$1,$2}')" "$(stat -c %s $f)" ${f}"
        echo ${out//.\//} >> ${controls_file}
        echo "Generated data: $out"
    done

    git add ${controls_file}
}

update_changed() {
    rm ${changed_file}
    echo "Last Buienradar updates ($(date +%d.%m.%Y))" > "${changed_file}"
    # echo "" >> ${changed_file}
    git log -5 HEAD --pretty="  %h %ad %s" --date=format:"%d.%m.%Y %H:%M" FHEM/  >> ${changed_file}

    git add CHANGED
}

# substitute
create_controlfile
# update_changed