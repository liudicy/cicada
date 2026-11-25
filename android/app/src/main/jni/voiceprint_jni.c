/* NativeVoiceprints (Voiceprints.kt) → linux/native/voiceprint.c, the voiceprint model the Linux app
 * runs; the same C, so an Android voiceprint is the Mac's. Only the calls, no logic of its own. */
#include <jni.h>
#include <stdint.h>

void *cvp_load(const char *path);
int cvp_embed_s16(void *model, const int16_t *samples, int n, float *out, int threads);
int cvp_dims(void *model);

JNIEXPORT jlong JNICALL
Java_com_wquguru_cicada_NativeVoiceprints_nativeLoad(JNIEnv *env, jobject self, jstring path) {
    (void)self;
    const char *p = (*env)->GetStringUTFChars(env, path, NULL);
    if (!p) return 0;
    void *m = cvp_load(p);
    (*env)->ReleaseStringUTFChars(env, path, p);
    /* Voiceprints.kt reads 256 numbers: a model of another size is no model. */
    return m && cvp_dims(m) == 256 ? (jlong)(intptr_t)m : 0;
}

/* 0 with a unit-length voiceprint in `out`, -1 when too short or it failed. Threads 0: one per
 * core, at most four (voiceprint.c). */
JNIEXPORT jint JNICALL
Java_com_wquguru_cicada_NativeVoiceprints_nativeEmbed(JNIEnv *env, jobject self, jlong model, jshortArray samples,
                                                    jint n, jfloatArray out) {
    (void)self;
    if (!model || n > (*env)->GetArrayLength(env, samples)) return -1;
    jshort *s = (*env)->GetShortArrayElements(env, samples, NULL);
    if (!s) return -1;
    float v[256];
    int r = cvp_embed_s16((void *)(intptr_t)model, (const int16_t *)s, n, v, 0);
    (*env)->ReleaseShortArrayElements(env, samples, s, JNI_ABORT);
    if (r == 0) (*env)->SetFloatArrayRegion(env, out, 0, 256, v);
    return r;
}
