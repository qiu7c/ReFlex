# 支持更旧版本的iOS设备(从15.6降到9.0)
TARGET = iphone:latest:9.0
ARCHS = arm64

# 名称和类型
LIBRARY_NAME = ReFlex

# 动态库类型 - 兼容各种越狱环境
LIBRARY_TYPE = dynamic

# 直接输出到当前目录
export THEOS_PACKAGE_DIR = $(CURDIR)

# Rootless
export THEOS_PACKAGE_SCHEME = rootless

# 设置路径
$(LIBRARY_NAME)_INSTALL_PATH = /Library/MobileSubstrate/DynamicLibraries

# 包含所有源文件（排除FLEX原版和重复文件）
$(LIBRARY_NAME)_FILES = $(shell find . \( -name '*.m' -o -name '*.mm' -o -name '*.c' \) | \
    grep -v "^./FLEX/" | \
    grep -v "x/retdec/" | \
    grep -v "x/retdec-build/" | \
    grep -v "x/Shared/FLEXKeychain.m" | \
    grep -v "x/Shared/FLEXKeychainQuery.m" | \
    grep -v "x/capstone/")

# Capstone核心文件（只包含ARM/ARM64架构）
CAPSTONE_CORE = $(shell find x/capstone -maxdepth 1 -name "*.c")
CAPSTONE_ARCH = $(shell find x/capstone/arch/AArch64 -name "*.c")
$(LIBRARY_NAME)_FILES += $(CAPSTONE_CORE) $(CAPSTONE_ARCH)

# 必要的框架和库
$(LIBRARY_NAME)_FRAMEWORKS = Foundation UIKit CoreGraphics CoreFoundation Security
$(LIBRARY_NAME)_PRIVATE_FRAMEWORKS = 

# 系统库
$(LIBRARY_NAME)_LIBRARIES = system xml2

# 链接器标志
$(LIBRARY_NAME)_LDFLAGS += -Wl,-no_warn_inits,-search_paths_first,-headerpad_max_install_names
$(LIBRARY_NAME)_CFLAGS = -fobjc-arc -include flex_fishhook.h \
                 -DFLEX_LIVE_OBJECTS_CONTROLLER_IS_VIEW_CONTROLLER=1 \
                 -DFLEX_LIVE_OBJECTS_VIEW_CONTROLLER=FLEXLiveObjectsController \
                 -Wno-unsupported-availability-guard \
                 -Wno-unused-but-set-variable \
                 -Wno-unguarded-availability-new \
                 -Wno-incompatible-pointer-types \
                 -Wno-deprecated-declarations \
                 -Wno-nullability-completeness \
                 -Wno-arc-retain-cycles \
                 -Wno-objc-missing-property-synthesis \
                 -Wno-unused-variable \
                 -Wno-unused-function \
                 -Wno-objc-protocol-method-implementation \
                 -Wno-implicit-function-declaration \
                 -Wno-nonnull \
                 -Wno-format \
                 -Wno-shift-op-parentheses \
                 -DCAPSTONE_HAS_AARCH64 \
                 -DCAPSTONE_USE_SYS_DYN_MEM \
                 -I./x \
                 -I./x/capstone/include

# 编译兼容性
$(LIBRARY_NAME)_CCFLAGS = -std=c++17 -Wno-unused-function -Wno-objc-missing-property-synthesis
$(LIBRARY_NAME)_OBJCFLAGS = -fobjc-arc

include $(THEOS)/makefiles/common.mk
include $(THEOS_MAKE_PATH)/library.mk

after-stage::
	@cp ReFlex.plist "$(THEOS_STAGING_DIR)/Library/MobileSubstrate/DynamicLibraries/"
	@install_name_tool -id @rpath/ReFlex.dylib "$(THEOS_STAGING_DIR)/Library/MobileSubstrate/DynamicLibraries/$(LIBRARY_NAME).dylib"
	@codesign --force --sign - "$(THEOS_STAGING_DIR)/Library/MobileSubstrate/DynamicLibraries/$(LIBRARY_NAME).dylib"
	@mkdir -p "$(THEOS_STAGING_DIR)/usr/share/doc/com.qiu7c.reflex"
	@cp ThirdPartyNotices/FLEX-LICENSE.txt ThirdPartyNotices/Capstone-LICENSE.txt "$(THEOS_STAGING_DIR)/usr/share/doc/com.qiu7c.reflex/"
