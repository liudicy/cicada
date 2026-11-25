# libcicada-voice.so: 说话人识别's voiceprint model. The C is the Linux app's (linux/native/voiceprint.c),
# not a copy, so both stay the Mac's; voiceprint_jni.c only hands calls over. Built by ndk-build
# from app/build.gradle.kts. 16 KB pages (Android 15+ phones) need the alignment flag.
LOCAL_PATH := $(call my-dir)

include $(CLEAR_VARS)
LOCAL_MODULE := cicada-voice
LOCAL_SRC_FILES := voiceprint_jni.c ../../../../../linux/native/voiceprint.c
LOCAL_CFLAGS := -O3 -Wall -Wextra
LOCAL_LDLIBS := -lm
LOCAL_LDFLAGS := -Wl,-z,max-page-size=16384
include $(BUILD_SHARED_LIBRARY)
