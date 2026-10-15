#!/bin/sh
cd "$(dirname "$0")"
exec godot --path "$PWD" "$@"
