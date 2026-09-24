// libbz2 ships in every Apple SDK (macOS, iOS, tvOS) but has no Swift module of
// its own. This is the whole bridge: NEXRAD Level II records are bzip2 blocks.
#include <bzlib.h>
