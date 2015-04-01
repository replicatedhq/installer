#!/bin/bash

EXEC="%s"
# EXEC="chisel"

#bash check
if [ ! "$BASH_VERSION" ] ; then
    echo "Please do not use sh to run this script ($0), just execute it directly" 1>&2
    exit 1
fi

#dependency check
if ! which curl > /dev/null; then
	echo "curl is not installed"
	exit 1
fi

#find OS
case `uname -s` in
Darwin) OS="darwin";;
Linux) OS="linux";;
*) echo "unknown os" && exit 1;;
esac
#find ARCH
if uname -m | grep 64 > /dev/null; then
	ARCH="amd64"
else
	ARCH="386"
fi

GH="https://github.com/jpillora/$EXEC"
#releases/latest will 302, inspect Location header, extract version
VERSION=`curl -sI $GH/releases/latest |
		grep Location |
		sed "s~^.*tag\/~~" | tr -d '\n' | tr -d '\r'`

if [ "$VERSION" = "" ]; then
	echo "Latest release not found: $GH"
	exit 1
fi

DIR="${EXEC}_${VERSION}_${OS}_${ARCH}"
echo "Downloading: $DIR"
URL="$GH/releases/download/$VERSION/$DIR"
case "$OS" in
darwin)
	curl -# -L "$URL.zip" > tmp.zip || fail "download failed"
	unzip -o -qq tmp.zip || fail "unzip failed"
	rm tmp.zip || fail "cleanup failed"
	;;
linux)
	curl -# -L "$URL.tar.gz" | tar zxf - || fail "download failed"
	;;
esac

cp $DIR/$EXEC $EXEC || fail "copy failed"
rm -r $DIR || fail "cleanup failed"
chmod +x $EXEC || fail "make failed"
echo "Done"