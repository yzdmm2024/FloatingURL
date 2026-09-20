# ============ FloatingURL Makefile：rootless tweak + 设置面板 ============
# 来源规范：系统-设置出现面板菜单的方法/模板（坑 A~H 全部规避）
# 改名清单：FloatingURL(TWEAK) / FloatingURLPrefs(Bundle) /
#          FUSettingsController(主类) / com.yzdmm.floatingurl(suite)

# 坑G：SDK 14.5（theos/sdks）——新 Xcode SDK 无私有框架 tbd，链不了 Preferences；
#      deployment 14.0 不影响跑 16.x
TARGET := iphone:clang:14.5:14.0
# 坑F：arm64e 设备上「设置」进程跑 arm64e，纯 arm64 的 bundle 加载报
#      「已损坏或丢失必要的资源」（dyld: incompatible architecture (have 'arm64', need 'arm64e')）
ARCHS = arm64 arm64e
THEOS_PACKAGE_SCHEME = rootless
INSTALL_TARGET_PROCESSES = SpringBoard

include $(THEOS)/makefiles/common.mk

# ===== Tweak 本体 =====
TWEAK_NAME = FloatingURL
FloatingURL_FILES = src/Tweak.xm
FloatingURL_CFLAGS = -fobjc-arc -Wno-deprecated-declarations -w
FloatingURL_FRAMEWORKS = UIKit Foundation CoreGraphics WebKit

# ===== 设置面板 PreferenceBundle =====
# Info.plist / Root.plist 手放 layout/Library/PreferenceBundles/FloatingURLPrefs.bundle/（坑D）
BUNDLE_NAME = FloatingURLPrefs
FloatingURLPrefs_FILES = Preferences/FUSettingsController.m
FloatingURLPrefs_INSTALL_PATH = /Library/PreferenceBundles
FloatingURLPrefs_FRAMEWORKS = UIKit Foundation PhotosUI
# 坑E：必须显式链接 Preferences（chained fixups 下 dynamic_lookup 会被 dyld 拒载）
FloatingURLPrefs_PRIVATE_FRAMEWORKS = Preferences
# 坑E：theos 只发 -framework 不发搜索路径，必须手动补 -F
FloatingURLPrefs_LDFLAGS = -F$(TARGET_PRIVATE_FRAMEWORK_PATH)
FloatingURLPrefs_CFLAGS = -fobjc-arc -fobjc-exceptions -w

include $(THEOS_MAKE_PATH)/tweak.mk
include $(THEOS_MAKE_PATH)/bundle.mk
