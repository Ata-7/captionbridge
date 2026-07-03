#include "whisper.h"

#include <ctype.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/sysctl.h>
#include <time.h>

static struct whisper_context * g_ctx = NULL;
static char * g_model_path = NULL;
static bool g_use_gpu = true;

static void free_model(void) {
    if (g_ctx != NULL) {
        whisper_free(g_ctx);
        g_ctx = NULL;
    }
    free(g_model_path);
    g_model_path = NULL;
}

static long long monotonic_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (long long) ts.tv_sec * 1000LL + ts.tv_nsec / 1000000LL;
}

static int worker_count(void) {
    int value = 0;
    size_t size = sizeof(value);
    if (sysctlbyname("hw.perflevel0.logicalcpu", &value, &size, NULL, 0) == 0 && value > 0) {
        return value;
    }
    if (sysctlbyname("hw.logicalcpu", &value, &size, NULL, 0) == 0 && value > 0) {
        return value > 4 ? 4 : value;
    }
    return 4;
}

static char * read_line(FILE * input) {
    size_t capacity = 256;
    size_t length = 0;
    char * line = (char *) malloc(capacity);
    if (line == NULL) {
        return NULL;
    }

    int ch = 0;
    while ((ch = fgetc(input)) != EOF) {
        if (ch == '\n') {
            break;
        }
        if (length + 1 >= capacity) {
            capacity *= 2;
            char * grown = (char *) realloc(line, capacity);
            if (grown == NULL) {
                free(line);
                return NULL;
            }
            line = grown;
        }
        line[length++] = (char) ch;
    }

    if (ch == EOF && length == 0) {
        free(line);
        return NULL;
    }

    line[length] = '\0';
    return line;
}

static bool read_exact(FILE * input, void * buffer, size_t count) {
    return fread(buffer, 1, count, input) == count;
}

static void write_response(const char * prefix, const char * request_id, const char * text, long long elapsed_ms) {
    const size_t text_length = text == NULL ? 0 : strlen(text);
    fprintf(stdout, "%s %s %lld %zu\n", prefix, request_id, elapsed_ms, text_length);
    if (text_length > 0) {
        fwrite(text, 1, text_length, stdout);
    }
    fputc('\n', stdout);
    fflush(stdout);
}

static void write_dual_response(const char * request_id, const char * text, const char * source_text, long long elapsed_ms) {
    const size_t text_length = text == NULL ? 0 : strlen(text);
    const size_t source_length = source_text == NULL ? 0 : strlen(source_text);
    fprintf(stdout, "OK2 %s %lld %zu %zu\n", request_id, elapsed_ms, text_length, source_length);
    if (text_length > 0) {
        fwrite(text, 1, text_length, stdout);
    }
    if (source_length > 0) {
        fwrite(source_text, 1, source_length, stdout);
    }
    fputc('\n', stdout);
    fflush(stdout);
}

static char * duplicate_bytes_as_string(const char * bytes, size_t length) {
    char * value = (char *) malloc(length + 1);
    if (value == NULL) {
        return NULL;
    }

    memcpy(value, bytes, length);
    value[length] = '\0';
    return value;
}

static char * trimmed_copy(const char * text) {
    if (text == NULL) {
        return duplicate_bytes_as_string("", 0);
    }

    const char * start = text;
    while (*start != '\0' && isspace((unsigned char) *start)) {
        start++;
    }

    const char * end = text + strlen(text);
    while (end > start && isspace((unsigned char) *(end - 1))) {
        end--;
    }

    return duplicate_bytes_as_string(start, (size_t) (end - start));
}

static char * append_text(char * base, size_t * length, size_t * capacity, const char * text) {
    const size_t text_length = strlen(text);
    const bool needs_space = *length > 0 && text_length > 0;
    const size_t extra = text_length + (needs_space ? 1 : 0);

    if (*length + extra + 1 > *capacity) {
        while (*length + extra + 1 > *capacity) {
            *capacity *= 2;
        }
        char * grown = (char *) realloc(base, *capacity);
        if (grown == NULL) {
            free(base);
            return NULL;
        }
        base = grown;
    }

    if (needs_space) {
        base[(*length)++] = ' ';
    }
    memcpy(base + *length, text, text_length);
    *length += text_length;
    base[*length] = '\0';
    return base;
}

static bool ensure_model(const char * model_path, bool use_gpu, char ** error_message) {
    if (g_ctx != NULL && g_model_path != NULL && strcmp(g_model_path, model_path) == 0 && (g_use_gpu == use_gpu || !g_use_gpu)) {
        return true;
    }

    free_model();

    struct whisper_context_params context_params = whisper_context_default_params();
    context_params.use_gpu = use_gpu;
    g_ctx = whisper_init_from_file_with_params(model_path, context_params);

    if (g_ctx == NULL && use_gpu) {
        context_params.use_gpu = false;
        g_ctx = whisper_init_from_file_with_params(model_path, context_params);
        use_gpu = false;
    }

    if (g_ctx == NULL) {
        *error_message = duplicate_bytes_as_string("failed to load Whisper model", 28);
        return false;
    }

    g_model_path = strdup(model_path);
    g_use_gpu = use_gpu;
    if (g_model_path == NULL) {
        *error_message = duplicate_bytes_as_string("out of memory", 13);
        free_model();
        return false;
    }

    return true;
}

static char * run_whisper_samples(const float * samples, int sample_count, const char * language, int audio_ctx, bool translate, bool high_quality, char ** error_message) {
    struct whisper_full_params params = whisper_full_default_params(high_quality ? WHISPER_SAMPLING_BEAM_SEARCH : WHISPER_SAMPLING_GREEDY);
    params.n_threads = worker_count();
    params.translate = translate;
    params.no_context = true;
    params.no_timestamps = true;
    params.single_segment = false;
    params.print_special = false;
    params.print_progress = false;
    params.print_realtime = false;
    params.print_timestamps = false;
    params.language = language;
    params.suppress_nst = true;
    params.temperature_inc = high_quality ? 0.2f : 0.0f;
    params.greedy.best_of = high_quality ? 3 : 1;
    params.beam_search.beam_size = high_quality ? 3 : 1;
    params.audio_ctx = audio_ctx;

    if (whisper_full(g_ctx, params, samples, sample_count) != 0) {
        *error_message = duplicate_bytes_as_string(translate ? "Whisper translation failed" : "Whisper transcription failed", translate ? 26 : 28);
        return NULL;
    }

    size_t capacity = 512;
    size_t length = 0;
    char * combined = (char *) calloc(capacity, 1);
    if (combined == NULL) {
        *error_message = duplicate_bytes_as_string("out of memory", 13);
        return NULL;
    }

    const int segment_count = whisper_full_n_segments(g_ctx);
    for (int index = 0; index < segment_count; index++) {
        char * segment = trimmed_copy(whisper_full_get_segment_text(g_ctx, index));
        if (segment == NULL) {
            free(combined);
            *error_message = duplicate_bytes_as_string("out of memory", 13);
            return NULL;
        }

        const float no_speech_prob = whisper_full_get_segment_no_speech_prob(g_ctx, index);
        if (!translate && no_speech_prob > 0.72f) {
            free(segment);
            continue;
        }

        if (segment[0] != '\0') {
            combined = append_text(combined, &length, &capacity, segment);
            if (combined == NULL) {
                free(segment);
                *error_message = duplicate_bytes_as_string("out of memory", 13);
                return NULL;
            }
        }
        free(segment);
    }

    return combined;
}

int main(void) {
    setvbuf(stdout, NULL, _IONBF, 0);
    setvbuf(stderr, NULL, _IONBF, 0);

    while (true) {
        char * line = read_line(stdin);
        if (line == NULL) {
            break;
        }

        char request_id[80] = {0};
        char language[16] = {0};
        char task[16] = "dual";
        size_t model_path_length = 0;
        int sample_rate = 0;
        int sample_count = 0;
        int audio_ctx = 768;
        int use_gpu_int = 1;

        const int fields = sscanf(
            line,
            "REQ %79s %zu %15s %d %d %d %d %15s",
            request_id,
            &model_path_length,
            language,
            &sample_rate,
            &sample_count,
            &audio_ctx,
            &use_gpu_int,
            task
        );
        free(line);

        if (fields < 7 || model_path_length == 0 || sample_rate <= 0 || sample_count <= 0) {
            write_response("ERR", request_id[0] == '\0' ? "unknown" : request_id, "invalid request header", 0);
            break;
        }

        char * model_path_bytes = (char *) malloc(model_path_length + 1);
        if (model_path_bytes == NULL || !read_exact(stdin, model_path_bytes, model_path_length)) {
            free(model_path_bytes);
            write_response("ERR", request_id, "failed to read model path", 0);
            break;
        }
        model_path_bytes[model_path_length] = '\0';

        const size_t audio_byte_count = (size_t) sample_count * sizeof(float);
        float * samples = (float *) malloc(audio_byte_count);
        if (samples == NULL || !read_exact(stdin, samples, audio_byte_count)) {
            free(model_path_bytes);
            free(samples);
            write_response("ERR", request_id, "failed to read audio samples", 0);
            break;
        }

        char * error_message = NULL;
        const long long start_ms = monotonic_ms();
        if (!ensure_model(model_path_bytes, use_gpu_int != 0, &error_message)) {
            write_response("ERR", request_id, error_message == NULL ? "failed to load model" : error_message, monotonic_ms() - start_ms);
            free(error_message);
            free(model_path_bytes);
            free(samples);
            continue;
        }

        if (strcmp(task, "source") == 0) {
            char * source_text = run_whisper_samples(samples, sample_count, language, audio_ctx, false, false, &error_message);
            const long long elapsed_ms = monotonic_ms() - start_ms;
            if (source_text == NULL || source_text[0] == '\0') {
                write_response("ERR", request_id, error_message == NULL ? "Whisper produced no subtitle text" : error_message, elapsed_ms);
            } else {
                write_response("OK", request_id, source_text, elapsed_ms);
            }

            free(source_text);
            free(error_message);
            free(model_path_bytes);
            free(samples);
            continue;
        }

        if (strcmp(task, "translate") == 0) {
            char * text = run_whisper_samples(samples, sample_count, language, audio_ctx, true, true, &error_message);
            const long long elapsed_ms = monotonic_ms() - start_ms;
            if (text == NULL || text[0] == '\0') {
                write_response("ERR", request_id, error_message == NULL ? "Whisper produced no subtitle text" : error_message, elapsed_ms);
            } else {
                write_response("OK", request_id, text, elapsed_ms);
            }

            free(text);
            free(error_message);
            free(model_path_bytes);
            free(samples);
            continue;
        }

        char * source_text = run_whisper_samples(samples, sample_count, language, audio_ctx, false, false, &error_message);
        if (source_text == NULL) {
            free(error_message);
            error_message = NULL;
            source_text = duplicate_bytes_as_string("", 0);
        }

        char * text = run_whisper_samples(samples, sample_count, language, audio_ctx, true, true, &error_message);
        const long long elapsed_ms = monotonic_ms() - start_ms;
        if (text == NULL || text[0] == '\0') {
            write_response("ERR", request_id, error_message == NULL ? "Whisper produced no subtitle text" : error_message, elapsed_ms);
        } else {
            write_dual_response(request_id, text, source_text, elapsed_ms);
        }

        free(text);
        free(source_text);
        free(error_message);
        free(model_path_bytes);
        free(samples);
    }

    free_model();
    return 0;
}
