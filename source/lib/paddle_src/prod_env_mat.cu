#include <cub/block/block_load.cuh>
#include <cub/block/block_radix_sort.cuh>
#include <cub/block/block_store.cuh>
#include "paddle/extension.h"

#define GOOGLE_CUDA 1

#include <iomanip>
#include "utilities.h"
#include "coord.h"
#include "fmt_nlist.h"
#include "region.h"
#include "neighbor_list.h"
#include "prod_env_mat.h"
#include "gpu_cuda.h"
#include <vector>

typedef long long int_64;

#define CHECK_INPUT(x) PD_CHECK(x.is_gpu(), #x " must be a GPU Tensor.")
#define CHECK_INPUT_DIM(x, value) PD_CHECK(x.shape().size() == value, #x "'s dim should be " #value ".")
// #define CHECK_INPUT(x) PD_CHECK(x.is_cpu(), #x " must be a CPU Tensor.")

__device__ inline double _sqrt(double x) { return sqrt(x); }
__device__ inline float _sqrt(float x) { return sqrtf(x); }
__device__ inline double _rsqrt(double x) { return rsqrt(x); }
__device__ inline float _rsqrt(float x) { return rsqrtf(x); }

template <typename FPTYPE>
static int
_norm_copy_coord_gpu(
    std::vector<paddle::Tensor>* tensor_list,
    FPTYPE *&coord_cpy,
    int *&type_cpy,
    int *&idx_mapping,
    int &nall,
    int &mem_cpy,
    const FPTYPE *coord,
    const FPTYPE *box,
    const int *type,
    const int &nloc,
    const int &max_cpy_trial,
    const float &rcut_r);

template <typename FPTYPE>
static int
_build_nlist_gpu(
    std::vector<paddle::Tensor> *tensor_list,
    int *&ilist,
    int *&numneigh,
    int **&firstneigh,
    int *&jlist,
    int &max_nnei,
    int &mem_nnei,
    const FPTYPE *coord,
    const int &nloc,
    const int &new_nall,
    const int &max_nnei_trial,
    const float &rcut_r);

static void
_map_nlist_gpu(
    int *nlist,
    const int *idx_mapping,
    const int &nloc,
    const int &nnei);

template <typename FPTYPE>
static void
_prepare_coord_nlist_gpu(
    std::vector<paddle::Tensor> *tensor_list,
    FPTYPE const **coord,
    FPTYPE *&coord_cpy,
    int const **type,
    int *&type_cpy,
    int *&idx_mapping,
    deepmd::InputNlist &inlist,
    int *&ilist,
    int *&numneigh,
    int **&firstneigh,
    int *&jlist,
    int *&nbor_list_dev,
    int &new_nall,
    int &mem_cpy,
    int &mem_nnei,
    int &max_nbor_size,
    const FPTYPE *box,
    const int *mesh_tensor_data,
    const int mesh_tensor_size,
    const int &nloc,
    const int &nei_mode,
    const float &rcut_r,
    const int &max_cpy_trial,
    const int &max_nnei_trial);

template <typename FPTYPE>
__device__ inline uint_64 encoding_nbor_info(const int type,
                                             const FPTYPE dist,
                                             const int index) {
  // nbor info checking:
  // the type of nbor atom must be smaller than 128
  // the distance of center atom between nbor atom must be smaller than 128
  // the index of nbor atom(including ghost region) must be smaller than
  // 16777216(1 << 24)
  if (type >= 128 || dist >= (FPTYPE)128.0 || index >= (1 << 24)) {
    asm("trap;");
  }
  return ((uint_64)type << 57) +
         (uint_64)((double)dist * ((uint_64)1 << 50)) / (1 << 24) * (1 << 24) +
         index;
}

__device__ inline void decoding_nbor_info(int& type,
                                          int& index,
                                          const uint_64 key) {
  type = key >> 57;
  index = key & 0xFFFFFF;
}

template <typename FPTYPE>
__global__ void get_i_idx(FPTYPE* i_idx, const int nloc, const FPTYPE* ilist) {
  const unsigned int idx = blockIdx.x * blockDim.x + threadIdx.x;
  if (idx >= nloc) {
    return;
  }
  i_idx[ilist[idx]] = idx;
}

// common part of prod_env_mat
template <typename Key, int BLOCK_THREADS, int ITEMS_PER_THREAD>
__launch_bounds__(BLOCK_THREADS) __global__
    void BlockSortKernel(Key* d_in,
                         Key* d_out)  // Tile of output
{
  enum { TILE_SIZE = BLOCK_THREADS * ITEMS_PER_THREAD };
  // Specialize BlockLoad type for our thread block (uses warp-striped loads for
  // coalescing, then transposes in shared memory to a blocked arrangement)
  typedef cub::BlockLoad<Key, BLOCK_THREADS, ITEMS_PER_THREAD,
                         cub::BLOCK_LOAD_WARP_TRANSPOSE>
      BlockLoadT;
  // Specialize BlockRadixSort type for our thread block
  typedef cub::BlockRadixSort<Key, BLOCK_THREADS, ITEMS_PER_THREAD>
      BlockRadixSortT;
  // Shared memory
  __shared__ union TempStorage {
    typename BlockLoadT::TempStorage load;
    typename BlockRadixSortT::TempStorage sort;
  } temp_storage;
  // Per-thread tile items
  Key items[ITEMS_PER_THREAD];
  // Our current block's offset
  int_64 block_offset = (int_64)blockIdx.x * TILE_SIZE;
  // Load items into a blocked arrangement
  BlockLoadT(temp_storage.load).Load(d_in + block_offset, items);
  // Barrier for smem reuse
  __syncthreads();
  // Sort keys
  BlockRadixSortT(temp_storage.sort).SortBlockedToStriped(items);
  // Store output in striped fashion
  cub::StoreDirectStriped<BLOCK_THREADS>(threadIdx.x, d_out + block_offset,
                                         items);
}


template <typename FPTYPE>
__device__ inline FPTYPE dev_dot(FPTYPE* arr1, FPTYPE* arr2) {
  return arr1[0] * arr2[0] + arr1[1] * arr2[1] + arr1[2] * arr2[2];
}

template <typename FPTYPE>
__device__ inline void spline5_switch(
    FPTYPE& vv, FPTYPE& dd, FPTYPE& xx, const float& rmin, const float& rmax) {
  if (xx < rmin) {
    dd = (FPTYPE)0.;
    vv = (FPTYPE)1.;
  } else if (xx < rmax) {
    FPTYPE uu = (xx - rmin) / (rmax - rmin);
    FPTYPE du = (FPTYPE)1. / (rmax - rmin);
    vv = uu * uu * uu *
             ((FPTYPE)-6. * uu * uu + (FPTYPE)15. * uu - (FPTYPE)10.) +
         (FPTYPE)1.;
    dd = ((FPTYPE)3. * uu * uu *
              ((FPTYPE)-6. * uu * uu + (FPTYPE)15. * uu - (FPTYPE)10.) +
          uu * uu * uu * ((FPTYPE)-12. * uu + (FPTYPE)15.)) *
         du;
  } else {
    dd = (FPTYPE)0.;
    vv = (FPTYPE)0.;
  }
}

template <typename FPTYPE>
__global__ void format_nlist_fill_a(uint_64* key,
                                    const FPTYPE* coord,
                                    const int* type,
                                    const int* numneigh,
                                    int** firstneigh,
                                    const float rcut,
                                    int* i_idx,
                                    const int MAX_NBOR_SIZE) {
  // <<<nloc, MAX_NBOR_SIZE>>>
  const int_64 idx = blockIdx.x;
  const unsigned int idy = blockIdx.y * blockDim.y + threadIdx.y;

  const int nsize = numneigh[i_idx[idx]];
  if (idy >= nsize) {
    return;
  }

  const int* nei_idx = firstneigh[i_idx[idx]];
  // dev_copy(nei_idx, &jlist[jrange[i_idx]], nsize);
  uint_64* key_in = key + idx * MAX_NBOR_SIZE;
  FPTYPE diff[3];
  const int& j_idx = nei_idx[idy];
  if (type[j_idx] < 0) return;
  for (int dd = 0; dd < 3; dd++) {
    diff[dd] = coord[j_idx * 3 + dd] - coord[idx * 3 + dd];
  }
  FPTYPE rr = _sqrt(dev_dot(diff, diff));
  if (rr <= rcut) {
    key_in[idy] = encoding_nbor_info(type[j_idx], rr, j_idx);
  }
}

template <typename FPTYPE>
__global__ void fill_nei_iter(int* nei_iter_dev,
                              const FPTYPE* key,
                              const int nloc,
                              const int max_nbor_size,
                              const int sec_size) {
  int_64 row = blockIdx.x;
  int col = blockIdx.y * blockDim.x + threadIdx.x;
  const FPTYPE* key_out = key + nloc * max_nbor_size + row * max_nbor_size;
  int nei_type_cur = -1, nbor_idx_cur = 0;
  int nei_type_pre = -1, nbor_idx_pre = 0;
  if (col < max_nbor_size && key_out[col] != key_out[max_nbor_size - 1]) {
    if (col >= 1)
      decoding_nbor_info(nei_type_pre, nbor_idx_pre, key_out[col - 1]);
    decoding_nbor_info(nei_type_cur, nbor_idx_cur, key_out[col]);
  }
  if (nei_type_cur != nei_type_pre) {
    nei_iter_dev[row * sec_size + nei_type_cur] = col;
  }
}

template <typename FPTYPE>
__global__ void format_nlist_fill_b(int* nlist,
                                    const int nlist_size,
                                    const int nloc,
                                    FPTYPE* key,
                                    const int* sec,
                                    const int sec_size,
                                    int* nei_iter_dev,
                                    const int max_nbor_size) {
  int_64 row = blockIdx.x;
  int col = blockIdx.y * blockDim.x + threadIdx.x;
  int* nei_iter = nei_iter_dev + row * sec_size;
  FPTYPE* key_out = key + nloc * max_nbor_size + row * max_nbor_size;
  int* row_nlist = nlist + row * nlist_size;
  if (col < max_nbor_size) {
    if (key_out[col] != key_out[max_nbor_size - 1]) {
      int nei_type = 0, nbor_idx = 0;
      decoding_nbor_info(nei_type, nbor_idx, key_out[col]);
      int out_indx = col - nei_iter[nei_type] + sec[nei_type];
      if (out_indx < sec[nei_type + 1]) {
        row_nlist[out_indx] = nbor_idx;
      }
    }
  }
}

template <typename FPTYPE>
__global__ void encoding_decoding_nbor_info(uint_64* key,
                                            int* out_type,
                                            int* out_index,
                                            const int* in_type,
                                            const FPTYPE* in_dist,
                                            const int* in_index,
                                            const int size_of_array) {
  const unsigned int idx = blockIdx.x * blockDim.x + threadIdx.x;
  if (idx >= size_of_array) {
    return;
  }

  key[idx] = encoding_nbor_info(in_type[idx], in_dist[idx], in_index[idx]);
  decoding_nbor_info(out_type[idx], out_index[idx], key[idx]);
}

template <typename FPTYPE>
void format_nbor_list_256(uint_64* key,
                          const FPTYPE* coord,
                          const int* type,
                          const deepmd::InputNlist& gpu_inlist,
                          const int& nloc,
                          const float& rcut,
                          int* i_idx) {
  const int LEN = 256;
  const int MAX_NBOR_SIZE = 256;
  const int nblock = (MAX_NBOR_SIZE + LEN - 1) / LEN;
  dim3 block_grid(nloc, nblock);
  dim3 thread_grid(1, LEN);
  format_nlist_fill_a<<<block_grid, thread_grid>>>(
      key, coord, type, gpu_inlist.numneigh, gpu_inlist.firstneigh, rcut, i_idx,
      MAX_NBOR_SIZE);
  DPErrcheck(cudaGetLastError());
  DPErrcheck(cudaDeviceSynchronize());
  const int ITEMS_PER_THREAD = 4;
  const int BLOCK_THREADS = MAX_NBOR_SIZE / ITEMS_PER_THREAD;
  // BlockSortKernel<NeighborInfo, BLOCK_THREADS,
  // ITEMS_PER_THREAD><<<g_grid_size, BLOCK_THREADS>>> (
  BlockSortKernel<uint_64, BLOCK_THREADS, ITEMS_PER_THREAD>
      <<<nloc, BLOCK_THREADS>>>(key, key + nloc * MAX_NBOR_SIZE);
  DPErrcheck(cudaGetLastError());
  DPErrcheck(cudaDeviceSynchronize());
}

template <typename FPTYPE>
void format_nbor_list_512(uint_64* key,
                          const FPTYPE* coord,
                          const int* type,
                          const deepmd::InputNlist& gpu_inlist,
                          const int& nloc,
                          const float& rcut,
                          int* i_idx) {
  const int LEN = 256;
  const int MAX_NBOR_SIZE = 512;
  const int nblock = (MAX_NBOR_SIZE + LEN - 1) / LEN;
  dim3 block_grid(nloc, nblock);
  dim3 thread_grid(1, LEN);
  format_nlist_fill_a<<<block_grid, thread_grid>>>(
      key, coord, type, gpu_inlist.numneigh, gpu_inlist.firstneigh, rcut, i_idx,
      MAX_NBOR_SIZE);
  DPErrcheck(cudaGetLastError());
  DPErrcheck(cudaDeviceSynchronize());
  const int ITEMS_PER_THREAD = 4;
  const int BLOCK_THREADS = MAX_NBOR_SIZE / ITEMS_PER_THREAD;
  // BlockSortKernel<NeighborInfo, BLOCK_THREADS,
  // ITEMS_PER_THREAD><<<g_grid_size, BLOCK_THREADS>>> (
  BlockSortKernel<uint_64, BLOCK_THREADS, ITEMS_PER_THREAD>
      <<<nloc, BLOCK_THREADS>>>(key, key + nloc * MAX_NBOR_SIZE);
  DPErrcheck(cudaGetLastError());
  DPErrcheck(cudaDeviceSynchronize());
}

template <typename FPTYPE>
void format_nbor_list_1024(uint_64* key,
                           const FPTYPE* coord,
                           const int* type,
                           const deepmd::InputNlist& gpu_inlist,
                           const int& nloc,
                           const float& rcut,
                           int* i_idx) {
  const int LEN = 256;
  const int MAX_NBOR_SIZE = 1024;
  const int nblock = (MAX_NBOR_SIZE + LEN - 1) / LEN;
  dim3 block_grid(nloc, nblock);
  dim3 thread_grid(1, LEN);
  format_nlist_fill_a<<<block_grid, thread_grid>>>(
      key, coord, type, gpu_inlist.numneigh, gpu_inlist.firstneigh, rcut, i_idx,
      MAX_NBOR_SIZE);
  DPErrcheck(cudaGetLastError());
  DPErrcheck(cudaDeviceSynchronize());
  const int ITEMS_PER_THREAD = 8;
  const int BLOCK_THREADS = MAX_NBOR_SIZE / ITEMS_PER_THREAD;
  // BlockSortKernel<NeighborInfo, BLOCK_THREADS,
  // ITEMS_PER_THREAD><<<g_grid_size, BLOCK_THREADS>>> (
  BlockSortKernel<uint_64, BLOCK_THREADS, ITEMS_PER_THREAD>
      <<<nloc, BLOCK_THREADS>>>(key, key + nloc * MAX_NBOR_SIZE);
  DPErrcheck(cudaGetLastError());
  DPErrcheck(cudaDeviceSynchronize());
}

template <typename FPTYPE>
void format_nbor_list_2048(uint_64* key,
                           const FPTYPE* coord,
                           const int* type,
                           const deepmd::InputNlist& gpu_inlist,
                           const int& nloc,
                           const float& rcut,
                           int* i_idx) {
  const int LEN = 256;
  const int MAX_NBOR_SIZE = 2048;
  const int nblock = (MAX_NBOR_SIZE + LEN - 1) / LEN;
  dim3 block_grid(nloc, nblock);
  dim3 thread_grid(1, LEN);
  format_nlist_fill_a<<<block_grid, thread_grid>>>(
      key, coord, type, gpu_inlist.numneigh, gpu_inlist.firstneigh, rcut, i_idx,
      MAX_NBOR_SIZE);
  DPErrcheck(cudaGetLastError());
  DPErrcheck(cudaDeviceSynchronize());
  const int ITEMS_PER_THREAD = 8;
  const int BLOCK_THREADS = MAX_NBOR_SIZE / ITEMS_PER_THREAD;
  // BlockSortKernel<NeighborInfo, BLOCK_THREADS,
  // ITEMS_PER_THREAD><<<g_grid_size, BLOCK_THREADS>>> (
  BlockSortKernel<uint_64, BLOCK_THREADS, ITEMS_PER_THREAD>
      <<<nloc, BLOCK_THREADS>>>(key, key + nloc * MAX_NBOR_SIZE);
  DPErrcheck(cudaGetLastError());
  DPErrcheck(cudaDeviceSynchronize());
}

template <typename FPTYPE>
void format_nbor_list_4096(uint_64* key,
                           const FPTYPE* coord,
                           const int* type,
                           const deepmd::InputNlist& gpu_inlist,
                           const int& nloc,
                           const float& rcut,
                           int* i_idx) {
  const int LEN = 256;
  const int MAX_NBOR_SIZE = 4096;
  const int nblock = (MAX_NBOR_SIZE + LEN - 1) / LEN;
  dim3 block_grid(nloc, nblock);
  dim3 thread_grid(1, LEN);
  format_nlist_fill_a<<<block_grid, thread_grid>>>(
      key, coord, type, gpu_inlist.numneigh, gpu_inlist.firstneigh, rcut, i_idx,
      MAX_NBOR_SIZE);
  DPErrcheck(cudaGetLastError());
  DPErrcheck(cudaDeviceSynchronize());
  const int ITEMS_PER_THREAD = 16;
  const int BLOCK_THREADS = MAX_NBOR_SIZE / ITEMS_PER_THREAD;
  // BlockSortKernel<NeighborInfo, BLOCK_THREADS,
  // ITEMS_PER_THREAD><<<g_grid_size, BLOCK_THREADS>>> (
  BlockSortKernel<uint_64, BLOCK_THREADS, ITEMS_PER_THREAD>
      <<<nloc, BLOCK_THREADS>>>(key, key + nloc * MAX_NBOR_SIZE);
  DPErrcheck(cudaGetLastError());
  DPErrcheck(cudaDeviceSynchronize());
}


template <typename FPTYPE, int THREADS_PER_BLOCK>
__global__ void compute_env_mat_a(FPTYPE* em,
                                  FPTYPE* em_deriv,
                                  FPTYPE* rij,
                                  const FPTYPE* coord,
                                  const FPTYPE* avg,
                                  const FPTYPE* std,
                                  const int* type,
                                  const int* nlist,
                                  const int nnei,
                                  const float rmin,
                                  const float rmax) {
  // <<<nloc, TPB>>>
  const int_64 bid = blockIdx.x;
  const unsigned int tid = threadIdx.x;
  if (type[bid] < 0) return;
  if (tid >= nnei) {
    return;
  }
  const int ndescrpt = nnei * 4;
  const int* row_nlist = nlist + bid * nnei;
  FPTYPE* row_rij = rij + bid * nnei * 3;
  FPTYPE* row_descript = em + bid * nnei * 4;
  FPTYPE* row_descript_deriv = em_deriv + bid * nnei * 12;
  for (int ii = tid; ii < nnei; ii += THREADS_PER_BLOCK) {
    const int idx_value = ii * 4;   // 4 components
    const int idx_deriv = ii * 12;  // 4 components time 3 directions
    if (row_nlist[ii] >= 0) {
      FPTYPE rr[3] = {0};
      FPTYPE dd[4] = {0};
      FPTYPE vv[12] = {0};
      const int j_idx = row_nlist[ii];
      for (int kk = 0; kk < 3; kk++) {
        rr[kk] = coord[j_idx * 3 + kk] - coord[bid * 3 + kk];
        row_rij[ii * 3 + kk] = rr[kk];
      }
      // const FPTYPE * rr = &row_rij[ii * 3];
      FPTYPE nr2 = dev_dot(rr, rr);
      FPTYPE inr = _rsqrt(nr2);
      FPTYPE nr = nr2 * inr;
      FPTYPE inr2 = inr * inr;
      FPTYPE inr4 = inr2 * inr2;
      FPTYPE inr3 = inr4 * nr;
      FPTYPE sw, dsw;
      spline5_switch(sw, dsw, nr, rmin, rmax);
      dd[0] = ((FPTYPE)1. / nr);  //* sw;
      dd[1] = (rr[0] / nr2);      //* sw;
      dd[2] = (rr[1] / nr2);      //* sw;
      dd[3] = (rr[2] / nr2);      //* sw;
      vv[0] = (rr[0] * inr3 * sw -
               dd[0] * dsw * rr[0] *
                   inr);  // avg[type[(idx_deriv + 0) / (ndescrpt * 3)] *
                          // ndescrpt + ((idx_deriv + 0) % (ndescrpt * 3)) / 3];
      vv[1] = (rr[1] * inr3 * sw -
               dd[0] * dsw * rr[1] *
                   inr);  // avg[type[(idx_deriv + 1) / (ndescrpt * 3)] *
                          // ndescrpt + ((idx_deriv + 1) % (ndescrpt * 3)) / 3];
      vv[2] = (rr[2] * inr3 * sw -
               dd[0] * dsw * rr[2] *
                   inr);  // avg[type[(idx_deriv + 2) / (ndescrpt * 3)] *
                          // ndescrpt + ((idx_deriv + 2) % (ndescrpt * 3)) / 3];
      // ****deriv of component x/r2
      vv[3] = (((FPTYPE)2. * rr[0] * rr[0] * inr4 - inr2) * sw -
               dd[1] * dsw * rr[0] *
                   inr);  // avg[type[(idx_deriv + 3) / (ndescrpt * 3)] *
                          // ndescrpt + ((idx_deriv + 3) % (ndescrpt * 3)) / 3];
      vv[4] = (((FPTYPE)2. * rr[0] * rr[1] * inr4) * sw -
               dd[1] * dsw * rr[1] *
                   inr);  // avg[type[(idx_deriv + 4) / (ndescrpt * 3)] *
                          // ndescrpt + ((idx_deriv + 4) % (ndescrpt * 3)) / 3];
      vv[5] = (((FPTYPE)2. * rr[0] * rr[2] * inr4) * sw -
               dd[1] * dsw * rr[2] *
                   inr);  // avg[type[(idx_deriv + 5) / (ndescrpt * 3)] *
                          // ndescrpt + ((idx_deriv + 5) % (ndescrpt * 3)) / 3];
      // ***deriv of component y/r2
      vv[6] = (((FPTYPE)2. * rr[1] * rr[0] * inr4) * sw -
               dd[2] * dsw * rr[0] *
                   inr);  // avg[type[(idx_deriv + 6) / (ndescrpt * 3)] *
                          // ndescrpt + ((idx_deriv + 6) % (ndescrpt * 3)) / 3];
      vv[7] = (((FPTYPE)2. * rr[1] * rr[1] * inr4 - inr2) * sw -
               dd[2] * dsw * rr[1] *
                   inr);  // avg[type[(idx_deriv + 7) / (ndescrpt * 3)] *
                          // ndescrpt + ((idx_deriv + 7) % (ndescrpt * 3)) / 3];
      vv[8] = (((FPTYPE)2. * rr[1] * rr[2] * inr4) * sw -
               dd[2] * dsw * rr[2] *
                   inr);  // avg[type[(idx_deriv + 8) / (ndescrpt * 3)] *
                          // ndescrpt + ((idx_deriv + 8) % (ndescrpt * 3)) / 3];
      // ***deriv of component z/r2
      vv[9] = (((FPTYPE)2. * rr[2] * rr[0] * inr4) * sw -
               dd[3] * dsw * rr[0] *
                   inr);  // avg[type[(idx_deriv + 9) / (ndescrpt * 3)] *
                          // ndescrpt + ((idx_deriv + 9) % (ndescrpt * 3)) / 3];
      vv[10] =
          (((FPTYPE)2. * rr[2] * rr[1] * inr4) * sw -
           dd[3] * dsw * rr[1] *
               inr);  // avg[type[(idx_deriv + 10) / (ndescrpt * 3)] * ndescrpt
                      // + ((idx_deriv + 10) % (ndescrpt * 3)) / 3];
      vv[11] =
          (((FPTYPE)2. * rr[2] * rr[2] * inr4 - inr2) * sw -
           dd[3] * dsw * rr[2] *
               inr);  // avg[type[(idx_deriv + 11) / (ndescrpt * 3)] * ndescrpt
                      // + ((idx_deriv + 11) % (ndescrpt * 3)) / 3];
      // 4 value components
      dd[0] *= sw;  // * em[idx * ndescrpt + idx_value + 0]);// - avg[type[idx]
                    // * ndescrpt + idx_value + 0]) / std[type[idx] * ndescrpt +
                    // idx_value + 0];
      dd[1] *= sw;  // * em[idx * ndescrpt + idx_value + 1]);// - avg[type[idx]
                    // * ndescrpt + idx_value + 1]) / std[type[idx] * ndescrpt +
                    // idx_value + 1];
      dd[2] *= sw;  // * em[idx * ndescrpt + idx_value + 2]);// - avg[type[idx]
                    // * ndescrpt + idx_value + 2]) / std[type[idx] * ndescrpt +
                    // idx_value + 2];
      dd[3] *= sw;  // * em[idx * ndescrpt + idx_value + 3]);// - avg[type[idx]
                    // * ndescrpt + idx_value + 3]) / std[type[idx] * ndescrpt +
                    // idx_value + 3];
      for (int ii = 0; ii < 12; ii++) {
        row_descript_deriv[idx_deriv + ii] =
            vv[ii] / std[type[bid] * ndescrpt + idx_value + ii / 3];
      }
      for (int ii = 0; ii < 4; ii++) {
        row_descript[idx_value + ii] =
            (dd[ii] - avg[type[bid] * ndescrpt + idx_value + ii]) /
            std[type[bid] * ndescrpt + idx_value + ii];
      }
    } else {
      // TODO: move it to the memset.
      row_descript[idx_value] -= avg[type[bid] * ndescrpt + idx_value] /
                                 std[type[bid] * ndescrpt + idx_value];
    }
  }
}

template <typename FPTYPE, int THREADS_PER_BLOCK>
__global__ void compute_env_mat_r(FPTYPE* em,
                                  FPTYPE* em_deriv,
                                  FPTYPE* rij,
                                  const FPTYPE* coord,
                                  const FPTYPE* avg,
                                  const FPTYPE* std,
                                  const int* type,
                                  const int* nlist,
                                  const int nnei,
                                  const float rmin,
                                  const float rmax) {
  // <<<nloc, TPB>>>
  const int_64 bid = blockIdx.x;
  const unsigned int tid = threadIdx.x;
  if (tid >= nnei) {
    return;
  }
  const int ndescrpt = nnei;
  const int* row_nlist = nlist + bid * nnei;
  FPTYPE* row_rij = rij + bid * nnei * 3;
  FPTYPE* row_em = em + bid * nnei;
  FPTYPE* row_em_deriv = em_deriv + bid * nnei * 3;
  for (int ii = tid; ii < nnei; ii += THREADS_PER_BLOCK) {
    const int idx_value = ii;      // 4 components
    const int idx_deriv = ii * 3;  // 4 components time 3 directions
    if (row_nlist[ii] >= 0) {
      FPTYPE rr[3] = {0};
      FPTYPE vv[3] = {0};
      FPTYPE dd = 0;
      const int& j_idx = row_nlist[ii];
      for (int kk = 0; kk < 3; kk++) {
        rr[kk] = coord[j_idx * 3 + kk] - coord[bid * 3 + kk];
        row_rij[ii * 3 + kk] = rr[kk];
      }
      // const FPTYPE * rr = &row_rij[ii * 3];
      FPTYPE nr2 = dev_dot(rr, rr);
      FPTYPE inr = _rsqrt(nr2);
      FPTYPE nr = nr2 * inr;
      FPTYPE inr2 = inr * inr;
      FPTYPE inr4 = inr2 * inr2;
      FPTYPE inr3 = inr4 * nr;
      FPTYPE sw, dsw;
      spline5_switch(sw, dsw, nr, rmin, rmax);
      dd = ((FPTYPE)1. / nr);  //* sw;
      vv[0] = (rr[0] * inr3 * sw -
               dd * dsw * rr[0] *
                   inr);  // avg[type[(idx_deriv + 0) / (ndescrpt * 3)] *
                          // ndescrpt + ((idx_deriv + 0) % (ndescrpt * 3)) / 3];
      vv[1] = (rr[1] * inr3 * sw -
               dd * dsw * rr[1] *
                   inr);  // avg[type[(idx_deriv + 1) / (ndescrpt * 3)] *
                          // ndescrpt + ((idx_deriv + 1) % (ndescrpt * 3)) / 3];
      vv[2] = (rr[2] * inr3 * sw -
               dd * dsw * rr[2] *
                   inr);  // avg[type[(idx_deriv + 2) / (ndescrpt * 3)] *
                          // ndescrpt + ((idx_deriv + 2) % (ndescrpt * 3)) / 3];

      // 4 value components
      dd *= sw;  // * em[idx * ndescrpt + idx_value + 0]);// - avg[type[idx] *
                 // ndescrpt + idx_value + 0]) / std[type[idx] * ndescrpt +
                 // idx_value + 0];
      for (int ii = 0; ii < 3; ii++) {
        row_em_deriv[idx_deriv + ii] =
            vv[ii] / std[type[bid] * ndescrpt + idx_value + ii / 3];
      }
      row_em[idx_value] = (dd - avg[type[bid] * ndescrpt + idx_value]) /
                          std[type[bid] * ndescrpt + idx_value];
    } else {
      // TODO: move it to the memset.
      row_em[idx_value] -= avg[type[bid] * ndescrpt + idx_value] /
                           std[type[bid] * ndescrpt + idx_value];
    }
  }
}

namespace deepmd {
template <typename FPTYPE>
void format_nbor_list_gpu_cuda(int* nlist,
                               const FPTYPE* coord,
                               const int* type,
                               const InputNlist& gpu_inlist,
                               int* array_int,
                               uint_64* array_longlong,
                               const int max_nbor_size,
                               const int nloc,
                               const int nall,
                               const float rcut,
                               const std::vector<int> sec) {
  const int LEN = 256;
  const int nnei = sec.back();
  const int nblock = (nloc + LEN - 1) / LEN;
  int* sec_dev = array_int;
  int* nei_iter = array_int + sec.size();  // = new int[sec_size];
  int* i_idx = array_int + sec.size() + nloc * sec.size();
  uint_64* key = array_longlong;
  assert(max_nbor_size == 256 || max_nbor_size == 512 ||
         max_nbor_size == 1024 || max_nbor_size == 2048 ||
         max_nbor_size == 4096);
  DPErrcheck(cudaMemset(nlist, -1, sizeof(int) * int_64(nloc) * nnei));
  DPErrcheck(cudaMemset(key, 0xffffffff,
                        sizeof(uint_64) * int_64(nloc) * max_nbor_size));
  DPErrcheck(cudaMemcpy(sec_dev, &sec[0], sizeof(int) * sec.size(),
                        cudaMemcpyHostToDevice));

  get_i_idx<<<nblock, LEN>>>(i_idx, nloc, gpu_inlist.ilist);
  DPErrcheck(cudaGetLastError());
  DPErrcheck(cudaDeviceSynchronize());

  if (max_nbor_size == 256) {
    format_nbor_list_256(key, coord, type, gpu_inlist, nloc, rcut, i_idx);
  } else if (max_nbor_size == 512) {
    format_nbor_list_512(key, coord, type, gpu_inlist, nloc, rcut, i_idx);
  } else if (max_nbor_size == 1024) {
    format_nbor_list_1024(key, coord, type, gpu_inlist, nloc, rcut, i_idx);
  } else if (max_nbor_size == 2048) {
    format_nbor_list_2048(key, coord, type, gpu_inlist, nloc, rcut, i_idx);
  } else if (max_nbor_size == 4096) {
    format_nbor_list_4096(key, coord, type, gpu_inlist, nloc, rcut, i_idx);
  }

  fill_nei_iter<<<dim3(nloc, (max_nbor_size + LEN - 1) / LEN), LEN>>>(
      nei_iter, key, nloc, max_nbor_size, sec.size());

  format_nlist_fill_b<<<dim3(nloc, (max_nbor_size + LEN - 1) / LEN), LEN>>>(
      nlist, nnei, nloc, key, sec_dev, sec.size(), nei_iter, max_nbor_size);
  DPErrcheck(cudaGetLastError());
  DPErrcheck(cudaDeviceSynchronize());
}
}

namespace deepmd {

template <typename FPTYPE>
void prod_env_mat_a_gpu_cuda(FPTYPE* em,
                             FPTYPE* em_deriv,
                             FPTYPE* rij,
                             int* nlist,
                             const FPTYPE* coord,
                             const int* type,
                             const InputNlist& gpu_inlist,
                             int* array_int,
                             uint_64* array_longlong,
                             const int max_nbor_size,
                             const FPTYPE* avg,
                             const FPTYPE* std,
                             const int nloc,
                             const int nall,
                             const float rcut,
                             const float rcut_smth,
                             const std::vector<int> sec,
                             const int* f_type) {
  if (f_type == NULL) {
    f_type = type;
  }
  const int nnei = sec.back();
  const int ndescrpt = nnei * 4;
  DPErrcheck(cudaMemset(em, 0, sizeof(FPTYPE) * int_64(nloc) * ndescrpt));
  DPErrcheck(
      cudaMemset(em_deriv, 0, sizeof(FPTYPE) * int_64(nloc) * ndescrpt * 3));
  DPErrcheck(cudaMemset(rij, 0, sizeof(FPTYPE) * int_64(nloc) * nnei * 3));

  format_nbor_list_gpu_cuda(nlist, coord, f_type, gpu_inlist, array_int,
                            array_longlong, max_nbor_size, nloc, nall, rcut,
                            sec);
  nborErrcheck(cudaGetLastError());
  nborErrcheck(cudaDeviceSynchronize());

  compute_env_mat_a<FPTYPE, TPB><<<nloc, TPB>>>(
      em, em_deriv, rij, coord, avg, std, type, nlist, nnei, rcut_smth, rcut);
  DPErrcheck(cudaGetLastError());
  DPErrcheck(cudaDeviceSynchronize());
}

template <typename FPTYPE>
void prod_env_mat_r_gpu_cuda(FPTYPE* em,
                             FPTYPE* em_deriv,
                             FPTYPE* rij,
                             int* nlist,
                             const FPTYPE* coord,
                             const int* type,
                             const deepmd::InputNlist& gpu_inlist,
                             int* array_int,
                             uint_64* array_longlong,
                             const int max_nbor_size,
                             const FPTYPE* avg,
                             const FPTYPE* std,
                             const int nloc,
                             const int nall,
                             const float rcut,
                             const float rcut_smth,
                             const std::vector<int> sec) {
  const int nnei = sec.back();
  const int ndescrpt = nnei * 1;
  DPErrcheck(cudaMemset(em, 0, sizeof(FPTYPE) * int_64(nloc) * ndescrpt));
  DPErrcheck(
      cudaMemset(em_deriv, 0, sizeof(FPTYPE) * int_64(nloc) * ndescrpt * 3));
  DPErrcheck(cudaMemset(rij, 0, sizeof(FPTYPE) * int_64(nloc) * nnei * 3));

  format_nbor_list_gpu_cuda(nlist, coord, type, gpu_inlist, array_int,
                            array_longlong, max_nbor_size, nloc, nall, rcut,
                            sec);
  nborErrcheck(cudaGetLastError());
  nborErrcheck(cudaDeviceSynchronize());

  compute_env_mat_r<FPTYPE, TPB><<<nloc, TPB>>>(
      em, em_deriv, rij, coord, avg, std, type, nlist, nnei, rcut_smth, rcut);
  DPErrcheck(cudaGetLastError());
  DPErrcheck(cudaDeviceSynchronize());
}
}


template <typename data_t>
void prod_env_mat_a_cuda_forward_kernel(
    int nsamples, int nloc, int ndescrpt, int nnei, int nall, int mem_cpy, int mem_nnei,
    int max_nbor_size, int nei_mode, float rcut_a, float rcut_r, float rcut_r_smth, int max_cpy_trial,
    int max_nnei_trial, bool b_nlist_map, const std::vector<int>& sec_a,
    const std::vector<int>& sec_r, deepmd::InputNlist gpu_inlist, int* nbor_list_dev, int* array_int, unsigned long long* array_longlong,
    data_t *p_em, data_t *p_em_deriv, data_t *p_rij, int *p_nlist,
    const data_t *p_coord, const data_t *p_box, const data_t *avg,
    const data_t *std, const int *p_type, const paddle::Tensor& mesh_tensor)
{

    for (int ff = 0; ff < nsamples; ++ff)
    {
        data_t *em = p_em + ff * nloc * ndescrpt;
        data_t *em_deriv = p_em_deriv + ff * nloc * ndescrpt * 3;
        data_t *rij = p_rij + ff * nloc * nnei * 3;
        int *nlist = p_nlist + ff * nloc * nnei;
        const data_t *coord = p_coord + ff * nall * 3;
        const data_t *box = p_box + ff * 9;
        const int *type = p_type + ff * nall;


        int *idx_mapping = NULL;
        int *ilist = NULL, *numneigh = NULL;
        int **firstneigh = NULL;
        deepmd::malloc_device_memory(firstneigh, nloc);
        int *jlist = NULL;
        data_t *coord_cpy;
        int *type_cpy;
        int frame_nall = nall;
        int mesh_tensor_size = static_cast<int>(mesh_tensor.size());
        std::vector<paddle::Tensor> tensor_list;
        _prepare_coord_nlist_gpu<data_t>(
            &tensor_list, &coord, coord_cpy, &type, type_cpy, idx_mapping,
            gpu_inlist, ilist, numneigh, firstneigh, jlist, nbor_list_dev,
            frame_nall, mem_cpy, mem_nnei, max_nbor_size,
            box, mesh_tensor.data<int>(), mesh_tensor_size, nloc, nei_mode, rcut_r, max_cpy_trial, max_nnei_trial);
        // allocate temp memory, temp memory must not be used after this operation!
        std::vector<int> int_temp_shape{int(sec_a.size()) + nloc * int(sec_a.size()) + nloc};
        auto int_temp = paddle::empty(
          int_temp_shape,
          paddle::DataType::FLOAT32,
          paddle::GPUPlace()
        );

        array_int = int_temp.mutable_data<int>();

        deepmd::malloc_device_memory(array_longlong, nloc * GPU_MAX_NBOR_SIZE * 2);
        // launch the gpu(nv) compute function

        deepmd::prod_env_mat_a_gpu_cuda(
            em, em_deriv, rij, nlist,
            coord, type, gpu_inlist, array_int, array_longlong, max_nbor_size, avg, std, nloc, frame_nall, rcut_r, rcut_r_smth, sec_a);
        if (b_nlist_map)
            _map_nlist_gpu(nlist, idx_mapping, nloc, nnei);
        deepmd::delete_device_memory(firstneigh);
        deepmd::delete_device_memory(array_longlong);
        array_longlong = NULL;
    }
}

void cum_sum(std::vector<int>& sec, const std::vector<int>& n_sel) {
  sec.resize(n_sel.size() + 1);
  sec[0] = 0;
  for (int ii = 1; ii < sec.size(); ++ii) {
    sec[ii] = sec[ii - 1] + n_sel[ii - 1];
  }
}


std::vector<paddle::Tensor> prod_env_mat_a_cuda_forward(
  const paddle::Tensor& coord_tensor,
  const paddle::Tensor& atype_tensor,
  const paddle::Tensor& box_tensor,
  const paddle::Tensor& mesh_tensor,
  const paddle::Tensor& t_avg_tensor,
  const paddle::Tensor& t_std_tensor,
  const paddle::Tensor& natoms_tensor,
  float rcut_a,
  float rcut_r,
  float rcut_r_smth,
  std::vector<int> sel_a,
  std::vector<int> sel_r
)
{
  std::vector<int> sec_a;
  std::vector<int> sec_r;
  int ndescrpt, ndescrpt_a, ndescrpt_r;
  int nnei, nnei_a, nnei_r, max_nbor_size;
  int mem_cpy, max_cpy_trial;
  int mem_nnei, max_nnei_trial;
  std::string device;
  int *array_int = NULL;
  unsigned long long *array_longlong = NULL;
  deepmd::InputNlist gpu_inlist;
  int *nbor_list_dev = NULL;
  float nloc_f, nall_f;

  cum_sum(sec_a, sel_a);
  cum_sum(sec_r, sel_r);
  ndescrpt_a = sec_a.back() * 4;
  ndescrpt_r = sec_r.back() * 1;
  ndescrpt = ndescrpt_a + ndescrpt_r;
  // std::cout << "ndescrpt = " << ndescrpt << std::endl;
  nnei_a = sec_a.back();
  nnei_r = sec_r.back();
  nnei = nnei_a + nnei_r;
  max_nbor_size = 1024;
  max_cpy_trial = 100;
  mem_cpy = 256;
  max_nnei_trial = 100;
  mem_nnei = 256;
  // std::cout << "natoms.dtype = " << natoms.dtype() << std::endl;
  // std::cout << "natoms.shape = ";
  // for (auto &x: natoms)
  // {
  //   std::cout << x << std::endl;
  // }
  // std::cout << std::endl;

  // std::cout <<  << std::endl;
  // std::cout << "natoms.numel = " << natoms.numel() << std::endl;
  // std::cout << "ckpt 1===============" << std::endl;
  // auto* natoms = natoms.data<int>();
  // std::cout << "natoms.numel() = " << natoms.numel() << std::endl;
  // std::cout << "ckpt 2===============" << std::endl;
  // std::cout << natoms[0] << std::endl;
  auto natoms = natoms_tensor.data<int>();
  int nloc = natoms[0]; // TODO: 使用natoms[0] 会段错误
  // std::cout << "nloc = " << nloc << std::endl;
  // std::cout << "ckpt 3===============" << std::endl;
  int nall = natoms[1]; // TODO: 使用natoms[1] 会段错误
  // std::cout << "nall = " << nloc << std::endl;
  // std::cout << "ckpt 4===============" << std::endl;
  // int ntypes = natoms.shape()[0] - 2;
  // std::cout << "ckpt 5===============" << std::endl;
  int nsamples = coord_tensor.shape()[0];
  // std::cout << "ckpt 6===============" << std::endl;

  int nei_mode = 0;
  bool b_nlist_map = false;
  if (mesh_tensor.shape()[0] == 16) {
    // lammps neighbor list
    nei_mode = 3;
  } else if (mesh_tensor.shape()[0] == 6) {
    // manual copied pbc
    assert(nloc == nall);
    nei_mode = 1;
    b_nlist_map = true;
  } else if (mesh_tensor.shape()[0] == 0) {
    // no pbc
    assert(nloc == nall);
    nei_mode = -1;
  } else {
    PD_THROW("invalid mesh tensor");
  }

  // create output tensors
  auto descrpt_tensor = paddle::empty(
    {nsamples, nloc * ndescrpt},
    coord_tensor.dtype(),
    coord_tensor.place()
  );
  // std::cout << "descrpt_tensor.shape = ";
  // for (auto &x: descrpt_tensor.shape())
  //   std::cout << x << " ";
  // std::cout << std::endl;

  auto descrpt_deriv_tensor = paddle::empty(
    {nsamples, nloc * ndescrpt * 3},
    coord_tensor.dtype(),
    coord_tensor.place()
  );
  // std::cout << "descrpt_deriv_tensor.shape = ";
  // for (auto &x: descrpt_deriv_tensor.shape())
  //   std::cout << x << " ";
  // std::cout << std::endl;

  auto rij_tensor = paddle::empty(
    {nsamples, nloc * nnei * 3},
    coord_tensor.dtype(),
    coord_tensor.place()
  );
  // std::cout << "rij_tensor.shape = ";
  // for (auto &x: rij_tensor.shape())
  //   std::cout << x << " ";
  // std::cout << std::endl;

  auto nlist_tensor = paddle::empty(
    {nsamples, nloc * nnei},
    coord_tensor.dtype(),
    coord_tensor.place()
  );
  // std::cout << "nlist_tensor.shape = ";
  // for (auto &x: nlist_tensor.shape())
  //   std::cout << x << " ";
  // std::cout << std::endl;

  // loop over samples
  PD_DISPATCH_FLOATING_TYPES(
    coord_tensor.type(), "prod_env_mat_a_cuda_forward_kernel", ([&] {
        prod_env_mat_a_cuda_forward_kernel<data_t>(
            nsamples, nloc, ndescrpt, nnei, nall, mem_cpy, mem_nnei, max_nbor_size,
            nei_mode, rcut_a, rcut_r, rcut_r_smth, max_cpy_trial, max_nnei_trial, b_nlist_map, sec_a, sec_r,
            gpu_inlist, nbor_list_dev, array_int, array_longlong,
            descrpt_tensor.mutable_data<data_t>(),
            descrpt_deriv_tensor.mutable_data<data_t>(),
            rij_tensor.mutable_data<data_t>(),
            nlist_tensor.mutable_data<int>(),
            coord_tensor.data<data_t>(),
            box_tensor.copy_to(paddle::CPUPlace(), false).data<data_t>(),
            t_avg_tensor.data<data_t>(),
            t_std_tensor.data<data_t>(),
            atype_tensor.data<int>(),
            mesh_tensor);
    }));
  return {descrpt_tensor, descrpt_deriv_tensor, rij_tensor, nlist_tensor};
}

template <typename FPTYPE>
static int
_norm_copy_coord_gpu(
    std::vector<paddle::Tensor>* tensor_list,
    FPTYPE *&coord_cpy,
    int *&type_cpy,
    int *&idx_mapping,
    int &nall,
    int &mem_cpy,
    const FPTYPE *coord,
    const FPTYPE *box,
    const int *type,
    const int &nloc,
    const int &max_cpy_trial,
    const float &rcut_r)
{
    // Tensor FPTYPE_temp;
    std::vector<int64_t> FPTYPE_temp_shape{nall*3};
    paddle::Tensor tmp_coord_tensor = paddle::Tensor(paddle::PlaceType::kGPU, FPTYPE_temp_shape);
    FPTYPE *tmp_coord = tmp_coord_tensor.mutable_data<FPTYPE>(paddle::PlaceType::kGPU);
    tensor_list->push_back(tmp_coord_tensor);
    cudaMemcpy(tmp_coord, coord, sizeof(FPTYPE) * nall * 3, cudaMemcpyDeviceToDevice);

    deepmd::Region<FPTYPE> region;
    deepmd::init_region_cpu(region, box);
    FPTYPE box_info[18];
    std::copy(region.boxt, region.boxt + 9, box_info);
    std::copy(region.rec_boxt, region.rec_boxt + 9, box_info + 9);
    int cell_info[23];
    deepmd::compute_cell_info(cell_info, rcut_r, region);
    const int loc_cellnum = cell_info[21];
    const int total_cellnum = cell_info[22];

    //Tensor double_temp;
    std::vector<int64_t> double_temp_shape {18};
    paddle::Tensor double_temp_tensor = paddle::Tensor(paddle::PlaceType::kGPU, double_temp_shape);
    FPTYPE *box_info_dev = double_temp_tensor.mutable_data<FPTYPE>(paddle::PlaceType::kGPU);
    tensor_list->push_back(double_temp_tensor);

    //Tensor int_temp;
    std::vector<int64_t> int_temp_shape {23+nloc*3+loc_cellnum+total_cellnum*3+total_cellnum*3+loc_cellnum+1+total_cellnum+1+nloc};
    paddle::Tensor int_temp_tensor = paddle::Tensor(paddle::PlaceType::kGPU, int_temp_shape);
    int *cell_info_dev = int_temp_tensor.mutable_data<int>(paddle::PlaceType::kGPU);
    int *int_data_dev = cell_info_dev + 23;
    tensor_list->push_back(int_temp_tensor);

    deepmd::memcpy_host_to_device(box_info_dev, box_info, 18);
    deepmd::memcpy_host_to_device(cell_info_dev, cell_info, 23);

    deepmd::Region<FPTYPE> region_dev;
    FPTYPE *new_boxt = region_dev.boxt;
    FPTYPE *new_rec_boxt = region_dev.rec_boxt;
    region_dev.boxt = box_info_dev;
    region_dev.rec_boxt = box_info_dev + 9;

    deepmd::normalize_coord_gpu(tmp_coord, nall, region_dev);


    int tt;
    paddle::Tensor cpy_temp_tensor = paddle::Tensor(paddle::PlaceType::kGPU);
    paddle::Tensor t_temp_tensor = paddle::Tensor(paddle::PlaceType::kGPU);
    for (tt = 0; tt < max_cpy_trial; ++tt)
    {
        std::vector<int64_t> cpy_temp_shape {mem_cpy * 3};
        std::vector<int64_t> t_temp_shape {mem_cpy * 2};
        cpy_temp_tensor.reshape(cpy_temp_shape);
        coord_cpy = cpy_temp_tensor.mutable_data<FPTYPE>(paddle::PlaceType::kGPU);
        t_temp_tensor.reshape(t_temp_shape);
        type_cpy = t_temp_tensor.mutable_data<int>(paddle::PlaceType::kGPU);

        idx_mapping = type_cpy + mem_cpy;
        int ret = deepmd::copy_coord_gpu(
            coord_cpy, type_cpy, idx_mapping, &nall, int_data_dev,
            tmp_coord, type, nloc, mem_cpy, loc_cellnum, total_cellnum, cell_info_dev, region_dev);
        if (ret == 0)
        {
            break;
        }
        else
        {
            mem_cpy *= 2;
        }
    }
    tensor_list->push_back(cpy_temp_tensor);
    tensor_list->push_back(t_temp_tensor);
    region_dev.boxt = new_boxt;
    region_dev.rec_boxt = new_rec_boxt;

    return (tt != max_cpy_trial);
}

template <typename FPTYPE>
static int
_build_nlist_gpu(
    std::vector<paddle::Tensor> *tensor_list,
    int *&ilist,
    int *&numneigh,
    int **&firstneigh,
    int *&jlist,
    int &max_nnei,
    int &mem_nnei,
    const FPTYPE *coord,
    const int &nloc,
    const int &new_nall,
    const int &max_nnei_trial,
    const float &rcut_r)
{
    //Tensor nlist_temp;
    std::vector<int64_t> nlist_temp_shape {nloc * 2};
    paddle::Tensor nlist_temp_tensor = paddle::Tensor(paddle::PlaceType::kGPU, nlist_temp_shape);
    ilist = nlist_temp_tensor.mutable_data<int>(paddle::PlaceType::kGPU);
    tensor_list->push_back(nlist_temp_tensor);
    numneigh = ilist + nloc;
    //Tensor jlist_temp;
    int *ind_data = NULL;

    std::vector<int *> firstneigh_host(nloc);
    int tt;
    paddle::Tensor jlist_temp_tensor = paddle::Tensor(paddle::PlaceType::kGPU);
    for (tt = 0; tt < max_nnei_trial; ++tt)
    {
        std::vector<int64_t> jlist_temp_shape {3 * nloc * mem_nnei};
        jlist_temp_tensor.reshape(jlist_temp_shape);
        jlist = jlist_temp_tensor.mutable_data<int>(paddle::PlaceType::kGPU);
        ind_data = jlist + nloc * mem_nnei;
        for (int ii = 0; ii < nloc; ++ii)
        {
            firstneigh_host[ii] = jlist + ii * mem_nnei;
        }
        deepmd::memcpy_host_to_device(firstneigh, firstneigh_host);
        deepmd::InputNlist inlist(nloc, ilist, numneigh, firstneigh);
        int ret = deepmd::build_nlist_gpu(
            inlist, &max_nnei, ind_data,
            coord, nloc, new_nall, mem_nnei, rcut_r);
        if (ret == 0)
        {
            break;
        }
        else
        {
            mem_nnei *= 2;
        }
    }
    tensor_list->push_back(jlist_temp_tensor);
    return (tt != max_nnei_trial);
}

static void
_map_nlist_gpu(
    int *nlist,
    const int *idx_mapping,
    const int &nloc,
    const int &nnei)
{
    deepmd::use_nlist_map(nlist, idx_mapping, nloc, nnei);
}

template <typename FPTYPE>
static void
_prepare_coord_nlist_gpu(
    std::vector<paddle::Tensor> *tensor_list,
    FPTYPE const **coord,
    FPTYPE *&coord_cpy,
    int const **type,
    int *&type_cpy,
    int *&idx_mapping,
    deepmd::InputNlist &inlist,
    int *&ilist,
    int *&numneigh,
    int **&firstneigh,
    int *&jlist,
    int *&nbor_list_dev,
    int &new_nall,
    int &mem_cpy,
    int &mem_nnei,
    int &max_nbor_size,
    const FPTYPE *box,
    const int *mesh_tensor_data,
    const int mesh_tensor_size,
    const int &nloc,
    const int &nei_mode,
    const float &rcut_r,
    const int &max_cpy_trial,
    const int &max_nnei_trial)
{
    inlist.inum = nloc;
    if (nei_mode != 3)
    {
        // build nlist by myself
        // normalize and copy coord
        if (nei_mode == 1)
        {
            int copy_ok = _norm_copy_coord_gpu(
                tensor_list, coord_cpy, type_cpy, idx_mapping, new_nall, mem_cpy,
                *coord, box, *type, nloc, max_cpy_trial, rcut_r);
            PD_CHECK(copy_ok, "cannot allocate mem for copied coords");
            *coord = coord_cpy;
            *type = type_cpy;

        }

        //build nlist
        int build_ok = _build_nlist_gpu(
            tensor_list, ilist, numneigh, firstneigh, jlist, max_nbor_size, mem_nnei,
            *coord, nloc, new_nall, max_nnei_trial, rcut_r);
        PD_CHECK(build_ok, "cannot allocate mem for nlist");
        if (max_nbor_size <= 1024)
        {
            max_nbor_size = 1024;
        }
        else if (max_nbor_size <= 2048)
        {
            max_nbor_size = 2048;
        }
        else
        {
            max_nbor_size = 4096;
        }
        inlist.ilist = ilist;
        inlist.numneigh = numneigh;
        inlist.firstneigh = firstneigh;
    }
    else
    {
        // update nbor list
        deepmd::InputNlist inlist_temp;
        inlist_temp.inum = nloc;
        deepmd::env_mat_nbor_update(
            inlist_temp, inlist, max_nbor_size, nbor_list_dev,
            mesh_tensor_data, mesh_tensor_size);
        // env_mat_nbor_update(
        //     inlist_temp, inlist, max_nbor_size, nbor_list_dev,
        //     mesh_tensor_data, mesh_tensor_size);
        PD_CHECK((max_numneigh(inlist_temp) <= GPU_MAX_NBOR_SIZE), "Assert failed, max neighbor size of atom(lammps) " + std::to_string(max_numneigh(inlist_temp)) + " is larger than " + std::to_string(GPU_MAX_NBOR_SIZE) + ", which currently is not supported by deepmd-kit.");
    }
}


std::vector<paddle::Tensor> ProdEnvMatAForward(
  const paddle::Tensor& coord_tensor,
  const paddle::Tensor& atype_tensor,
  const paddle::Tensor& mesh_tensor,
  const paddle::Tensor& box_tensor,
  const paddle::Tensor& t_avg_tensor,
  const paddle::Tensor& t_std_tensor,
  const paddle::Tensor& natoms_tensor,
  float rcut_a,
  float rcut_r,
  float rcut_r_smth,
  std::vector<int> sel_a,
  std::vector<int> sel_r
) {
  if (coord_tensor.is_gpu()) {
    return prod_env_mat_a_cuda_forward(
      coord_tensor,
      atype_tensor,
      mesh_tensor,
      box_tensor,
      t_avg_tensor,
      t_std_tensor,
      natoms_tensor,
      rcut_a,
      rcut_r,
      rcut_r_smth,
      sel_a,
      sel_r
    );
  } else {
    PD_THROW("Unsupported device type for forward function of custom relu operator.");
  }
}


std::vector<std::vector<int64_t>> ProdEnvMatAInferShape(
  std::vector<int64_t> coord_shape,
  std::vector<int64_t> atype_shape,
  std::vector<int64_t> box_shape,
  std::vector<int64_t> mesh_shape,
  std::vector<int64_t> t_avg_shape,
  std::vector<int64_t> t_std_shape,
  std::vector<int64_t> natoms_shape,
  float rcut_a,
  float rcut_r,
  float rcut_r_smth,
  const std::vector<int>& sel_a,
  const std::vector<int>& sel_r
) {
  int64_t nloc = /*natoms[0]*/ 192;
  int64_t nall = /*natoms[1]*/ 192;

  std::vector<int> sec_a;
  std::vector<int> sec_r;
  cum_sum(sec_a, sel_a);
  cum_sum(sec_r, sel_r);

  int64_t nsamples = coord_shape[0];
  int64_t ndescrpt_a = sec_a.back() * 4;
  int64_t ndescrpt_r = sec_r.back() * 1;
  int64_t ndescrpt = ndescrpt_a + ndescrpt_r;

  int64_t nnei_a = sec_a.back();
  int64_t nnei_r = sec_r.back();
  int64_t nnei = nnei_a + nnei_r;

  std::vector<int64_t> descrpt_shape = {nsamples, nloc * ndescrpt};
  std::vector<int64_t> descrpt_deriv_shape = {nsamples, nloc * ndescrpt * 3};
  std::vector<int64_t> rij_shape = {nsamples, nloc * nnei * 3};
  std::vector<int64_t> nlist_shape = {nsamples, nloc * nnei};
  return {descrpt_shape, descrpt_deriv_shape, rij_shape, nlist_shape};
}

std::vector<paddle::DataType> ProdEnvMatAInferDtype(
  paddle::DataType coord_dtype,
  paddle::DataType atype_dtype,
  paddle::DataType box_dtype,
  paddle::DataType mesh_dtype,
  paddle::DataType t_avg_dtype,
  paddle::DataType t_std_dtype,
  paddle::DataType natoms_dtype
) {
  return {coord_dtype, coord_dtype, coord_dtype, coord_dtype};
}


PD_BUILD_OP(prod_env_mat_a)
    .Inputs({"coord", "atype", "box", "mesh", "t_avg", "t_std", "natoms"})
    .Outputs({"descrpt", "descrpt_deriv", "rij", "nlist"})
    .Attrs({"rcut_a: float", "rcut_r: float", "rcut_r_smth: float", "sel_a: std::vector<int>", "sel_r: std::vector<int>"})
    .SetKernelFn(PD_KERNEL(ProdEnvMatAForward))
    .SetInferShapeFn(PD_INFER_SHAPE(ProdEnvMatAInferShape))
    .SetInferDtypeFn(PD_INFER_DTYPE(ProdEnvMatAInferDtype));