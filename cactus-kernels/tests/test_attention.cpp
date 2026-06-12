#include "test_utils.h"
#include <vector>
#include <cmath>

using namespace TestUtils;

bool test_rms_norm() {
    const size_t batch = 4, dim = 128;
    std::vector<__fp16> input(batch * dim), weight(dim), output(batch * dim);
    fill_random_fp16(input, -1.0f, 1.0f);
    for (size_t i = 0; i < dim; i++) weight[i] = static_cast<__fp16>(1.0f);
    cactus_rms_norm_f16(input.data(), weight.data(), output.data(), batch, dim, 1e-6f);
    for (size_t b = 0; b < batch; b++) {
        float sum_sq = 0.0f;
        for (size_t d = 0; d < dim; d++) { float v = static_cast<float>(output[b * dim + d]); sum_sq += v * v; }
        if (std::abs(std::sqrt(sum_sq / dim) - 1.0f) > 0.05f) return false;
    }
    return true;
}

bool test_layer_norm() {
    const size_t batch = 4, dim = 128;
    std::vector<__fp16> input(batch * dim), weight(dim), bias(dim), output(batch * dim);
    fill_random_fp16(input, -1.0f, 1.0f);
    for (size_t i = 0; i < dim; i++) { weight[i] = static_cast<__fp16>(1.0f); bias[i] = static_cast<__fp16>(0.0f); }
    cactus_layer_norm_f16(input.data(), weight.data(), bias.data(), output.data(), batch, dim, 1e-5f);
    for (size_t b = 0; b < batch; b++) {
        float mean = 0.0f;
        for (size_t d = 0; d < dim; d++) mean += static_cast<float>(output[b * dim + d]);
        mean /= dim;
        if (std::abs(mean) > 0.05f) return false;
    }
    return true;
}

bool test_softmax() {
    const size_t rows = 8, vocab = 128;
    std::vector<__fp16> input(rows * vocab), output(rows * vocab);
    fill_random_fp16(input, -5.0f, 5.0f);
    cactus_softmax_f16(input.data(), output.data(), rows, 1, vocab);
    for (size_t r = 0; r < rows; r++) {
        float sum = 0.0f;
        for (size_t j = 0; j < vocab; j++) {
            float v = static_cast<float>(output[r * vocab + j]);
            if (v < 0.0f || v > 1.0f) return false;
            sum += v;
        }
        if (std::abs(sum - 1.0f) > 0.01f) return false;
    }
    return true;
}

bool test_rope() {
    const size_t batch = 1, seq = 4, heads = 2, dim = 16;
    std::vector<__fp16> input(batch * seq * heads * dim), output(batch * seq * heads * dim);
    for (auto& v : input) v = static_cast<__fp16>(1.0f);
    cactus_rope_f16(input.data(), output.data(), batch, seq, heads, dim, 0, 10000.0f);
    for (size_t i = 0; i < heads * dim; i++)
        if (std::abs(static_cast<float>(output[i]) - 1.0f) > 0.01f) return false;
    bool changed = false;
    for (size_t i = heads * dim; i < output.size(); i++)
        if (std::abs(static_cast<float>(output[i]) - 1.0f) > 0.001f) { changed = true; break; }
    return changed;
}

bool test_attention_f16() {
    const size_t batch = 1, seq = 8, heads = 2, kv_heads = 2, dim = 16;
    std::vector<__fp16> q(batch * seq * heads * dim), k(batch * seq * kv_heads * dim);
    std::vector<__fp16> v(batch * seq * kv_heads * dim), out(batch * seq * heads * dim);
    fill_random_fp16(q, -0.5f, 0.5f); fill_random_fp16(k, -0.5f, 0.5f); fill_random_fp16(v, -0.5f, 0.5f);
    float scale = 1.0f / std::sqrt(static_cast<float>(dim));
    cactus_attention_f16(q.data(), k.data(), v.data(), out.data(), batch, seq, seq, heads, kv_heads, dim, scale,
                         nullptr, 0, 0, true, false, false, 0, 0.0f);
    for (size_t i = 0; i < out.size(); i++)
        if (!std::isfinite(static_cast<float>(out[i]))) return false;
    return true;
}

bool run_benchmarks() {
    auto bench = [](const char* label, auto fn) {
        fn();
        Timer t;
        for (int i = 0; i < 100; i++) fn();
        double ms = t.elapsed_ms() / 100.0;
        std::cout << "  ⚡ " << std::left << std::setw(30) << label
                  << std::fixed << std::setprecision(3) << ms << " ms\n";
    };

    {
        const size_t b = 1024, d = 1024;
        std::vector<__fp16> in(b * d), w(d), out(b * d);
        fill_random_fp16(in); for (size_t i = 0; i < d; i++) w[i] = static_cast<__fp16>(1.0f);
        bench("rms_norm 1024x1024", [&]{ cactus_rms_norm_f16(in.data(), w.data(), out.data(), b, d, 1e-6f); });
    }
    {
        const size_t b = 1024, d = 1024;
        std::vector<__fp16> in(b * d), w(d), bias(d), out(b * d);
        fill_random_fp16(in);
        for (size_t i = 0; i < d; i++) { w[i] = static_cast<__fp16>(1.0f); bias[i] = static_cast<__fp16>(0.0f); }
        bench("layer_norm 1024x1024", [&]{ cactus_layer_norm_f16(in.data(), w.data(), bias.data(), out.data(), b, d, 1e-5f); });
    }
    {
        const size_t rows = 1024, cols = 1024;
        std::vector<__fp16> in(rows * cols), out(rows * cols);
        fill_random_fp16(in, -5.0f, 5.0f);
        bench("softmax 1024x1024", [&]{ cactus_softmax_f16(in.data(), out.data(), rows, 1, cols); });
    }
    {
        const size_t b = 1, s = 256, h = 16, d = 128;
        std::vector<__fp16> in(b * s * h * d), out(b * s * h * d);
        fill_random_fp16(in, -0.5f, 0.5f);
        bench("rope 256x16x128", [&]{ cactus_rope_f16(in.data(), out.data(), b, s, h, d, 0, 10000.0f); });
    }
    {
        const size_t b = 1, s = 256, h = 16, kv = 8, d = 128;
        std::vector<__fp16> q(b * s * h * d), k(b * s * kv * d), v(b * s * kv * d), out(b * s * h * d);
        fill_random_fp16(q, -0.3f, 0.3f); fill_random_fp16(k, -0.3f, 0.3f); fill_random_fp16(v, -0.3f, 0.3f);
        float sc = 1.0f / std::sqrt(static_cast<float>(d));
        bench("attention seq=256 h=16 d=128", [&]{
            cactus_attention_f16(q.data(), k.data(), v.data(), out.data(), b, s, s, h, kv, d, sc,
                                 nullptr, 0, 0, true, false, false, 0, 0.0f);
        });
    }
    return true;
}

int main() {
    TestRunner runner("Attention, RoPE & Normalization");
    runner.run_test("rms_norm", test_rms_norm());
    runner.run_test("layer_norm", test_layer_norm());
    runner.run_test("softmax", test_softmax());
    runner.run_test("rope", test_rope());
    runner.run_test("attention_f16", test_attention_f16());
    runner.print_benchmarks_header();
    runner.run_bench("benchmarks", run_benchmarks());
    runner.print_summary();
    return runner.all_passed() ? 0 : 1;
}
