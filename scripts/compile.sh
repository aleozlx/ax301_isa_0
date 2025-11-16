#!/bin/bash
PROJECT="seg_test"

quartus_sh --flow compile $PROJECT

if [ $? -eq 0 ]; then
    echo -e "\n\033[32m✓ Compilation successful\033[0m\n"
    cat output_files/${PROJECT}.fit.summary
else
    echo -e "\n\033[31m✗ Compilation failed\033[0m"
    exit 1
fi
