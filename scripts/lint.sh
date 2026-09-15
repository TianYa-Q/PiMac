#!/bin/sh
set -eu

cd "$(dirname "$0")/.."
swift format lint --strict --recursive Sources Tests Package.swift
