#ifndef ANDROID_API_LEVEL_H
#define ANDROID_API_LEVEL_H

#ifdef __cplusplus
extern "C" {
#endif

/* HarmonyOS stub: pretend a reasonably modern Android API level. */
static inline int android_get_device_api_level(void) {
    return 29;
}

#ifdef __cplusplus
}
#endif

#endif
