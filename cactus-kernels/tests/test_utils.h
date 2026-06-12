#pragma once

#include "../cactus_kernels.h"
#include "../src/threading.h"
#include <string>
#include <iostream>
#include <iomanip>
#include <chrono>
#include <vector>
#include <cmath>
#include <random>

namespace TestUtils {

class Timer {
public:
    Timer() : start_(std::chrono::high_resolution_clock::now()) {}
    double elapsed_ms() const {
        auto now = std::chrono::high_resolution_clock::now();
        return std::chrono::duration<double, std::milli>(now - start_).count();
    }
private:
    std::chrono::time_point<std::chrono::high_resolution_clock> start_;
};

class TestRunner {
public:
    explicit TestRunner(const std::string& suite_name) : suite_(suite_name), passed_(0), failed_(0) {
        std::cout << "\n╔══════════════════════════════════════════════════════════════════════════════════════╗\n"
                  << "║ Running " << std::left << std::setw(73) << suite_name << "║\n"
                  << "╚══════════════════════════════════════════════════════════════════════════════════════╝\n";
    }

    void run_test(const std::string& name, bool result) {
        if (result) {
            std::cout << "✓ PASS │ " << std::left << std::setw(25) << name << std::endl;
            passed_++;
        } else {
            std::cout << "✗ FAIL │ " << std::left << std::setw(25) << name << std::endl;
            failed_++;
        }
    }

    void run_bench(const std::string& /*name*/, bool result) {
        if (!result) failed_++;
    }

    void print_benchmarks_header() const {
        std::cout << "── benchmarks ──────────────────────────────────────────────────────────────────────────\n";
    }

    void print_summary() const {
        std::cout << "────────────────────────────────────────────────────────────────────────────────────────\n";
        if (failed_ == 0) {
            std::cout << "✓ All " << passed_ << " tests passed!\n";
        } else {
            std::cout << "✗ " << failed_ << " of " << (passed_ + failed_) << " tests failed!\n";
        }
    }

    bool all_passed() const { return failed_ == 0; }

private:
    std::string suite_;
    int passed_;
    int failed_;
};

inline bool compare_arrays(const __fp16* a, const __fp16* b, size_t n, float tol = 1e-2f) {
    for (size_t i = 0; i < n; i++) {
        if (std::abs(static_cast<float>(a[i]) - static_cast<float>(b[i])) > tol) {
            std::cerr << "  mismatch at [" << i << "]: " << static_cast<float>(a[i])
                      << " vs " << static_cast<float>(b[i]) << std::endl;
            return false;
        }
    }
    return true;
}

inline void fill_random_fp16(std::vector<__fp16>& v, float lo = -1.0f, float hi = 1.0f) {
    static std::mt19937 gen(42);
    std::uniform_real_distribution<float> dis(lo, hi);
    for (auto& x : v) x = static_cast<__fp16>(dis(gen));
}

} // namespace TestUtils
