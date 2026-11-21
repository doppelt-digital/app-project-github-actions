#!/usr/bin/env bash
# Source in the native action process so npm, Expo, Gradle, CocoaPods and Xcode
# all inherit an absent optional value, rather than an explicit empty override.
if [ -n "${EXPO_PUBLIC_API_URL+x}" ] && [ -z "${EXPO_PUBLIC_API_URL//[[:space:]]/}" ]; then
  unset EXPO_PUBLIC_API_URL
fi
