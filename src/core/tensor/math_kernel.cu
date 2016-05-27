/************************************************************
*
* Licensed to the Apache Software Foundation (ASF) under one
* or more contributor license agreements.  See the NOTICE file
* distributed with this work for additional information
* regarding copyright ownership.  The ASF licenses this file
* to you under the Apache License, Version 2.0 (the
* "License"); you may not use this file except in compliance
* with the License.  You may obtain a copy of the License at
*
*   http://www.apache.org/licenses/LICENSE-2.0
*
* Unless required by applicable law or agreed to in writing,
* software distributed under the License is distributed on an
* "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
* KIND, either express or implied.  See the License for the
* specific language governing permissions and limitations
* under the License.
*
*************************************************************/

#include "singa_config.h"
#ifdef USE_CUDA
#include <cmath>
#include <algorithm>
#include <cfloat>
#include "./math_kernel.h"

#define CU2DBLOCK_X 32
#define CU2DBLOCK_Y 32

#define CU1DBLOCK 1024
#define CU1DBLOCKF 1024.0

namespace singa {
// Cuda Kernel Functions
namespace cuda {
__global__ void kernel_softmax_loss(const float *prob, const int *label,
                                    float *loss, int n, int dim) {
  int index = blockIdx.x * blockDim.x + threadIdx.x;
  int num_threads = blockDim.x * gridDim.x;
  for (; index < n; index += num_threads) {
    float prob_of_truth = prob[index * dim + label[index]];
    loss[index] -= std::log(max(prob_of_truth, FLT_MIN));
  }
}

__global__ void kernel_softmax_gradient(float *grad, const int *label, int n,
                                        int dim, float scale) {
  int index = blockIdx.x * blockDim.x + threadIdx.x;
  int num_threads = blockDim.x * gridDim.x;
  for (; index < n; index += num_threads) {
    int pos = index * dim + label[index];
    grad[pos] = (grad[pos] - 1.0f) * scale;
  }
}

__global__ void kernel_sum_vec(const float *data, float *sum, int n) {
  int THREADS = blockDim.x;

  __shared__ float aux[CU1DBLOCK];
  int steps = (n - 1) / THREADS + 1;
  aux[threadIdx.x] = data[threadIdx.x];

  for (int i = 1; i < steps; ++i) {
    if (threadIdx.x + i * THREADS < n) {
      aux[threadIdx.x] += data[threadIdx.x + i * THREADS];
    }
  }

  int total_threads = THREADS;
  __syncthreads();

  while (total_threads > 1) {
    int half_point = ((1 + total_threads) >> 1);
    if (threadIdx.x < half_point) {
      if (threadIdx.x + half_point < total_threads) {
        aux[threadIdx.x] += aux[threadIdx.x + half_point];
      }
    }
    __syncthreads();
    total_threads = ((total_threads + 1) >> 1);
  }

  __syncthreads();
  *sum = aux[0];
}

__global__ void kernel_sum_col(const float *src_mat_data, float *dst_vec_data,
                               int rows, int cols, int stride) {
  int index = blockIdx.x * blockDim.x + threadIdx.x;
  int num_threads = blockDim.x * gridDim.x;
  for (; index < rows; index += num_threads) {
    dst_vec_data[index] = 0.0f;
    for (int k = 0; k < cols; k++) {
      dst_vec_data[index] += src_mat_data[index * stride + k];
    }
  }
}

__global__ void kernel_sum_row(const float *src_mat_data, float *dst_vec_data,
                               int rows, int cols, int stride) {
  int j = blockIdx.x;
  int THREADS = blockDim.x;
  if (j >= cols) {
    return;
  }

  __shared__ float aux[CU1DBLOCK];
  int steps = (rows - 1) / THREADS + 1;
  aux[threadIdx.x] = src_mat_data[j + threadIdx.x * stride];
  for (int i = 1; i < steps; ++i) {
    if (threadIdx.x + i * THREADS < rows) {
      aux[threadIdx.x] +=
          src_mat_data[j + (threadIdx.x + i * THREADS) * stride];
    }
  }

  int total_threads = THREADS;
  __syncthreads();
  while (total_threads > 1) {
    int half_point = ((1 + total_threads) >> 1);
    if (threadIdx.x < half_point) {
      if (threadIdx.x + half_point < total_threads) {
        aux[threadIdx.x] += aux[threadIdx.x + half_point];
      }
    }
    __syncthreads();
    total_threads = ((total_threads + 1) >> 1);
  }

  __syncthreads();
  dst_vec_data[j] = aux[0];
}

__global__ void kernel_add_vec_row(const float *src_vec_data,
                                   const float *src_mat_data,
                                   float *des_mat_data, int rows, int cols,
                                   int stride) {
  int i = blockIdx.x * blockDim.x + threadIdx.x;
  int j = blockIdx.y * blockDim.y + threadIdx.y;
  int num_threads_x = blockDim.x * gridDim.x;
  int num_threads_y = blockDim.y * gridDim.y;
  int index = 0;
  for (; i < cols && j < rows; i += num_threads_x, j += num_threads_y) {
    index = j * stride + i;
    des_mat_data[index] = src_mat_data[index] + src_vec_data[i];
  }
}
__global__ void kernel_add(const float *src1, const float *src2, float *out,
                           int n) {
  int index = blockIdx.x * blockDim.x + threadIdx.x;
  int num_threads = blockDim.x * gridDim.x;
  for (; index < n; index += num_threads) {
    out[index] = src1[index] + src2[index];
  }
}

__global__ void kernel_sub(const float *src1, const float *src2, float *out,
                           int n) {
  int index = blockIdx.x * blockDim.x + threadIdx.x;
  int num_threads = blockDim.x * gridDim.x;
  for (; index < n; index += num_threads) {
    out[index] = src1[index] - src2[index];
  }
}
__global__ void kernel_exp(const float *src_data, float *des_data, int n) {
  int index = blockIdx.x * blockDim.x + threadIdx.x;
  int num_threads = blockDim.x * gridDim.x;
  for (; index < n; index += num_threads) {
    des_data[index] = std::exp(src_data[index]);
  }
}

__global__ void kernel_log(const float *src_data, float *des_data, int n) {
  int index = blockIdx.x * blockDim.x + threadIdx.x;
  int num_threads = blockDim.x * gridDim.x;
  for (; index < n; index += num_threads) {
    des_data[index] = std::log(src_data[index]);
  }
}

__global__ void kernel_sigmoid(const float *src_data, float *des_data, int n) {
  int index = blockIdx.x * blockDim.x + threadIdx.x;
  int num_threads = blockDim.x * gridDim.x;
  for (; index < n; index += num_threads) {
    des_data[index] = 1.0f / (1.0f + expf(-src_data[index]));
  }
}

__global__ void kernel_sigmoid_grad(const float *src_data, float *des_data,
                                    int n) {
  int index = blockIdx.x * blockDim.x + threadIdx.x;
  int num_threads = blockDim.x * gridDim.x;
  for (; index < n; index += num_threads) {
    des_data[index] = src_data[index] * (1.0f - src_data[index]);
  }
}

__global__ void kernel_relu(const float *src_data, float *des_data, int n) {
  int index = blockIdx.x * blockDim.x + threadIdx.x;
  int num_threads = blockDim.x * gridDim.x;
  for (; index < n; index += num_threads) {
    des_data[index] = max(src_data[index], 0.0f);
  }
}

__global__ void kernel_relu_grad(const float *src_data, float *des_data,
                                 int n) {
  int index = blockIdx.x * blockDim.x + threadIdx.x;
  int num_threads = blockDim.x * gridDim.x;
  for (; index < n; index += num_threads) {
    des_data[index] = src_data[index] > 0.0f ? 1.0f : 0.0f;
  }
}

__global__ void kernel_tanh(const float *src_data, float *des_data, int n) {
  int index = blockIdx.x * blockDim.x + threadIdx.x;
  int num_threads = blockDim.x * gridDim.x;
  for (; index < n; index += num_threads) {
    des_data[index] = tanhf(src_data[index]);
  }
}

__global__ void kernel_tanh_grad(const float *src_data, float *des_data,
                                 int n) {
  int index = blockIdx.x * blockDim.x + threadIdx.x;
  int num_threads = blockDim.x * gridDim.x;
  for (; index < n; index += num_threads) {
    des_data[index] = (1.0f - src_data[index] * src_data[index]);
  }
}

__global__ void kernel_softplus(const float *src_data, float *des_data, int n) {
  int index = blockIdx.x * blockDim.x + threadIdx.x;
  int num_threads = blockDim.x * gridDim.x;
  for (; index < n; index += num_threads) {
    des_data[index] = logf(1 + expf(src_data[index]));
  }
}

__global__ void kernel_softplus_grad(const float *src_data, float *des_data,
                                     int n) {
  int index = blockIdx.x * blockDim.x + threadIdx.x;
  int num_threads = blockDim.x * gridDim.x;
  for (; index < n; index += num_threads) {
    des_data[index] = 1.0f / (1.0f + expf(-src_data[index]));
  }
}

__global__ void kernel_square(const float *src_data, float *des_data, int n) {
  int index = blockIdx.x * blockDim.x + threadIdx.x;
  int num_threads = blockDim.x * gridDim.x;
  for (; index < n; index += num_threads) {
    des_data[index] = src_data[index] * src_data[index];
  }
}

__global__ void kernel_square_grad(const float *src_data, float *des_data,
                                   int n) {
  int index = blockIdx.x * blockDim.x + threadIdx.x;
  int num_threads = blockDim.x * gridDim.x;
  for (; index < n; index += num_threads) {
    des_data[index] = 2 * src_data[index];
  }
}

__global__ void kernel_sqrt(const float *src_data, float *des_data, int n) {
  int index = blockIdx.x * blockDim.x + threadIdx.x;
  int num_threads = blockDim.x * gridDim.x;
  for (; index < n; index += num_threads) {
    des_data[index] = std::sqrt(src_data[index]);
  }
}

__global__ void kernel_pow(const float *src_data_a, const float *src_data_b,
                           float *des_data, int n) {
  int index = blockIdx.x * blockDim.x + threadIdx.x;
  int num_threads = blockDim.x * gridDim.x;
  for (; index < n; index += num_threads) {
    des_data[index] = std::pow(src_data_a[index], src_data_b[index]);
  }
}

__global__ void kernel_mult(const float *src_data_a, const float *src_data_b,
                            float *des_data, int n) {
  int index = blockIdx.x * blockDim.x + threadIdx.x;
  int num_threads = blockDim.x * gridDim.x;
  for (; index < n; index += num_threads) {
    des_data[index] = src_data_a[index] * src_data_b[index];
  }
}

__global__ void kernel_mult(const float *src_data_a, const float x,
                            float *des_data, int n) {
  int index = blockIdx.x * blockDim.x + threadIdx.x;
  int num_threads = blockDim.x * gridDim.x;
  for (; index < n; index += num_threads) {
    des_data[index] = src_data_a[index] * x;
  }
}

__global__ void kernel_div(const float *src_data_a, const float *src_data_b,
                           float *des_data, int n) {
  int index = blockIdx.x * blockDim.x + threadIdx.x;
  int num_threads = blockDim.x * gridDim.x;
  for (; index < n; index += num_threads) {
    des_data[index] = src_data_a[index] / src_data_b[index];
  }
}

__global__ static void kernel_set_value(float *data, float value, int n) {
  int index = blockIdx.x * blockDim.x + threadIdx.x;
  int num_threads = blockDim.x * gridDim.x;
  for (; index < n; index += num_threads) {
    data[index] = value;
  }
}

__global__ void kernel_threshold(const float *src_data, float *des_data,
                                 float alpha, int n) {
  int index = blockIdx.x * blockDim.x + threadIdx.x;
  int num_threads = blockDim.x * gridDim.x;
  for (; index < n; index += num_threads) {
    des_data[index] = src_data[index] < alpha ? 1.0f : 0.0f;
  }
}
void sum(int n, const float *in, float *out) {
  int threads_per_block = n > CU1DBLOCK ? CU1DBLOCK : n;
  //  here, we only need one block
  int num_blocks = 1;

  kernel_sum_vec << <num_blocks, threads_per_block>>> (in, out, n);
}

void sum_row(int rows, int cols, int stride, const float *in, float *out) {
  int threads_per_block = rows > CU1DBLOCK ? CU1DBLOCK : rows;
  int num_blocks = cols;

  kernel_sum_row << <num_blocks, threads_per_block>>>
      (in, out, rows, cols, stride);
}

void sum_col(int rows, int cols, int stride, const float *in, float *out) {
  int threads_per_block = cols > CU1DBLOCK ? CU1DBLOCK : cols;
  int num_blocks = rows;

  kernel_sum_col << <num_blocks, threads_per_block>>>
      (in, out, rows, cols, stride);
}
void add_row(int rows, int cols, int stride, const float *in_row,
             const float *in_mat, float *out) {
  dim3 threads_per_block(CU2DBLOCK_X, CU2DBLOCK_Y);
  dim3 num_blocks(
      cols / threads_per_block.x + (cols % threads_per_block.x == 0 ? 0 : 1),
      rows / threads_per_block.y + (rows % threads_per_block.y == 0 ? 0 : 1));
  kernel_add_vec_row << <num_blocks, threads_per_block>>>
      (in_row, in_mat, out, rows, cols, stride);
}
void add(int n, const float *a, const float *b, float *out) {
  kernel_add << <ceil(n / CU1DBLOCKF), CU1DBLOCKF>>> (a, b, out, n);
}
void sub(int n, const float *a, const float *b, float *out) {
  kernel_sub << <ceil(n / CU1DBLOCKF), CU1DBLOCKF>>> (a, b, out, n);
}
void exp(int n, const float *in, float *out) {
  kernel_exp << <ceil(n / CU1DBLOCKF), CU1DBLOCKF>>> (in, out, n);
}

void log(int n, const float *in, float *out) {
  kernel_log << <ceil(n / CU1DBLOCKF), CU1DBLOCKF>>> (in, out, n);
}

void sigmoid(int n, const float *in, float *out) {
  kernel_sigmoid << <ceil(n / CU1DBLOCKF), CU1DBLOCKF>>> (in, out, n);
}

void sigmoid_grad(int n, const float *in, float *out) {
  kernel_sigmoid_grad << <ceil(n / CU1DBLOCKF), CU1DBLOCKF>>> (in, out, n);
}

void relu(int n, const float *in, float *out) {
  kernel_relu << <ceil(n / CU1DBLOCKF), CU1DBLOCKF>>> (in, out, n);
}

void relu_grad(int n, const float *in, float *out) {
  kernel_relu_grad << <ceil(n / CU1DBLOCKF), CU1DBLOCKF>>> (in, out, n);
}

void tanh(int n, const float *in, float *out) {
  kernel_tanh << <ceil(n / CU1DBLOCKF), CU1DBLOCKF>>> (in, out, n);
}

void tanh_grad(int n, const float *in, float *out) {
  kernel_tanh_grad << <ceil(n / CU1DBLOCKF), CU1DBLOCKF>>> (in, out, n);
}

void softplus(int n, const float *in, float *out) {
  kernel_softplus << <ceil(n / CU1DBLOCKF), CU1DBLOCKF>>> (in, out, n);
}

void softplus_grad(int n, const float *in, float *out) {
  kernel_softplus_grad << <ceil(n / CU1DBLOCKF), CU1DBLOCKF>>> (in, out, n);
}

void square(int n, const float *in, float *out) {
  kernel_square << <ceil(n / CU1DBLOCKF), CU1DBLOCKF>>> (in, out, n);
}

void square_grad(int n, const float *in, float *out) {
  kernel_square_grad << <ceil(n / CU1DBLOCKF), CU1DBLOCKF>>> (in, out, n);
}

void sqrt(int n, const float *in, float *out) {
  kernel_sqrt << <ceil(n / CU1DBLOCKF), CU1DBLOCKF>>> (in, out, n);
}

void pow(int n, const float *a, const float *b, float *out) {
  kernel_pow << <ceil(n / CU1DBLOCKF), CU1DBLOCKF>>> (a, b, out, n);
}

void mult(int n, const float *a, const float *b, float *out) {
  kernel_mult << <ceil(n / CU1DBLOCKF), CU1DBLOCKF>>> (a, b, out, n);
}

void mult(int n, const float *a, const float x, float *out) {
  kernel_mult << <ceil(n / CU1DBLOCKF), CU1DBLOCKF>>> (a, x, out, n);
}

void div(int n, const float *a, const float *b, float *out) {
  kernel_div << <ceil(n / CU1DBLOCKF), CU1DBLOCKF>>> (a, b, out, n);
}

void set_value(int n, float v, float *out) {
  kernel_set_value << <ceil(n / CU1DBLOCKF), CU1DBLOCKF>>> (out, v, n);
}

void threshold(int n, float alpha, const float *in, float *out) {
  kernel_threshold << <ceil(n / CU1DBLOCKF), CU1DBLOCKF>>> (in, out, alpha, n);
}

// follow the consistency guide for math API
__global__ void KernelDiv(const size_t num, const float alpha, const float *in,
                          float *out) {
  for (size_t idx = blockIdx.x * blockDim.x + threadIdx.x; idx < num;
       idx += blockDim.x * gridDim.x) {
    out[idx] = alpha / in[idx];
  }
}

__global__ void KernelGE(const int num, const float *in, const float x,
                         float *out) {
  for (size_t idx = blockIdx.x * blockDim.x + threadIdx.x; idx < num;
       idx += blockDim.x * gridDim.x) {
    out[idx] = in[idx] >= x ? 1.0f : 0.0f;
  }
}
__global__ void KernelGT(const int num, const float *in, const float x,
                         float *out) {
  for (size_t idx = blockIdx.x * blockDim.x + threadIdx.x; idx < num;
       idx += blockDim.x * gridDim.x) {
    out[idx] = in[idx] > x ? 1.0f : 0.0f;
  }
}
__global__ void KernelLE(const int num, const float *in, const float x,
                         float *out) {
  for (size_t idx = blockIdx.x * blockDim.x + threadIdx.x; idx < num;
       idx += blockDim.x * gridDim.x) {
    out[idx] = in[idx] <= x ? 1.0f : 0.0f;
  }
}

__global__ void KernelLT(const int num, const float *in, const float x,
                         float *out) {
  for (size_t idx = blockIdx.x * blockDim.x + threadIdx.x; idx < num;
       idx += blockDim.x * gridDim.x) {
    out[idx] = in[idx] < x ? 1.0f : 0.0f;
  }
}

__global__ void KernelSet(const size_t num, const float x, float *out) {
  for (size_t idx = blockIdx.x * blockDim.x + threadIdx.x; idx < num;
       idx += blockDim.x * gridDim.x) {
    out[idx] = x;
  }
}

__global__
void KernelComputeCrossEntropy(const size_t batchsize, const size_t dim, const float* p,
    const int* t, float* loss) {
  size_t sample = blockIdx.x * blockDim.x + threadIdx.x;
  size_t num_threads = blockDim.x * gridDim.x;
  for (; sample < batchsize; sample += num_threads) {
    float prob_of_truth = p[sample * dim + t[sample]];
    loss[sample] -= std::log(max(prob_of_truth, FLT_MIN));
  }
}

__global__
void KernelSoftmaxCrossEntropyBwd(const size_t batchsize, const size_t dim, const float* p,
    const int* t, float* grad) {
  size_t sample = blockIdx.x * blockDim.x + threadIdx.x;
  size_t num_threads = blockDim.x * gridDim.x;
  for (; sample < batchsize; sample += num_threads) {
    size_t pos = sample * dim + t[sample];
    grad[pos] = p[pos] - 1.0f;  // TODO(wangwei) Consider p and grad are diff
  }
}
void Div(const size_t num, float alpha, const float *in, float *out,
         cudaStream_t s) {
  KernelDiv << <ceil(num / CU1DBLOCKF), CU1DBLOCKF>>> (num, alpha, in, out);
}

void GT(const size_t num, const float *in, const float x, float *out,
        cudaStream_t s) {
  KernelGT << <ceil(num / CU1DBLOCKF), CU1DBLOCKF>>> (num, in, x, out);
}
void GE(const size_t num, const float *in, const float x, float *out,
        cudaStream_t s) {
  KernelGE << <ceil(num / CU1DBLOCKF), CU1DBLOCKF>>> (num, in, x, out);
}
void LT(const size_t num, const float *in, const float x, float *out,
        cudaStream_t s) {
  KernelLT << <ceil(num / CU1DBLOCKF), CU1DBLOCKF>>> (num, in, x, out);
}
void LE(const size_t num, const float *in, const float x, float *out,
        cudaStream_t s) {
  KernelLE << <ceil(num / CU1DBLOCKF), CU1DBLOCKF>>> (num, in, x, out);
}

void ComputeCrossEntropy(size_t batchsize, const size_t dim, const float* p,
    const int *t, float *loss, cudaStream_t stream) {
  KernelComputeCrossEntropy<<<ceil(batchsize/CU1DBLOCKF), CU1DBLOCKF>>>(batchsize,
      dim, p, t, loss);
}

void Set(const size_t num, const float x, float *out, cudaStream_t s) {
  KernelSet<<<ceil(num / CU1DBLOCKF), CU1DBLOCKF>>>(num, x, out);
}

void SoftmaxCrossEntropyBwd(size_t batchsize, const size_t dim, const float* p,
    const int *t, float *grad, cudaStream_t stream) {
  KernelSoftmaxCrossEntropyBwd<<<ceil(batchsize/CU1DBLOCKF), CU1DBLOCKF>>>(batchsize,
      dim, p, t, grad);
}
}  // namespace cuda
}  // namespace singa

#endif  // USE_CUDA
