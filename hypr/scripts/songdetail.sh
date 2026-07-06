#!/bin/bash

artist=$(playerctl metadata xesam:artist 2>/dev/null)
title=$(playerctl metadata xesam:title 2>/dev/null)

case "$1" in
--title)
  echo "$title"
  ;;
--artist)
  echo "$artist"
  ;;
esac
