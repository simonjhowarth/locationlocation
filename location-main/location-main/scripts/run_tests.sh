#!/bin/bash
set -euo pipefail

echo "Installing dependencies..."
flutter pub get

echo "Running Flutter tests..."
flutter test

echo "Tests finished."
