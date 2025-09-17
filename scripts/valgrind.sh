#!/bin/bash

echo "Running Valgrind..."
echo "Building with debug symbols..."

# Build with debug
nim c --stackTrace:on --lineTrace:on --debugger:native --opt:none -d:debug --threads:on -d:ssl src/niffler.nim
echo ""
echo "/exit" | timeout 10s valgrind -s --tool=memcheck --leak-check=full --show-leak-kinds=all --track-origins=yes ./src/niffler 2>&1 | tee valgrind_output.log

echo "Valgrind output saved to valgrind_output.log"
