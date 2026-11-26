// Box3D, Erin Catto's 3D physics engine (MIT), built and installed with CMake so pkg-config finds `box3d`:
//
//   cmake -S box3d -B build -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=$HOME/.local \
//     -DBOX3D_SAMPLES=OFF -DBOX3D_UNIT_TESTS=OFF -DCMAKE_POSITION_INDEPENDENT_CODE=ON
//   cmake --build build && cmake --install build
//   export PKG_CONFIG_PATH=$HOME/.local/lib/pkgconfig
#include <box3d/box3d.h>
