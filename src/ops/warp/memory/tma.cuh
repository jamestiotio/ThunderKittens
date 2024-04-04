#pragma once

#include "../../../common/common.cuh"
#include "../../../types/types.cuh"

#include <cuda.h>
#include <iostream>

namespace kittens {
/**
 * @brief A namespace for all of ThunderKittens' TMA functionality.
*/
namespace tma {

namespace detail {

template<typename T> concept st_type_2d_tma_layout = (
    ducks::st::all<T> && 
    (
        std::is_same_v<typename T::layout, ducks::st_layout::naive> || 
        std::is_same_v<typename T::layout, ducks::st_layout::tma_swizzle>
    )
);
template<typename T> concept st_type_wgmma_row_layout = (
    ducks::st::all<T> && std::is_same_v<typename T::layout, ducks::st_layout::wgmma_row_0b>
);
template<typename T> concept st_type_wgmma_col_t_layout = (
    ducks::st::all<T> && std::is_same_v<typename T::layout, ducks::st_layout::wgmma_col_t_0b>
);
template<typename T> concept st_type_tma_layout = (
    st_type_2d_tma_layout<T> || st_type_wgmma_row_layout<T> || st_type_wgmma_col_t_layout<T>
);

}; 

/* ----------   Create tensor map descriptor (HOST)  ---------- */

/**
* @brief Creates a tensor map for the given source tensor.
*
* This function creates a tensor map (CUtensorMap) for the specified source shared tile  type. The tensor map
* is used to describe the shape and layout of the tensor in memory. The function sets up the tensor
* map based on the provided source tensor pointer and the layout specified by the ST template parameter.
*
* @tparam ST The source tensor type, which must be TMA-compatible.
* @tparam num_blocks The number of tiles present in global memory.
* @param tma_map Pointer to the CUtensorMap object to be initialized.
* @param src Pointer to the source tensor data in global memory.
*/
template<detail::st_type_tma_layout ST, int num_blocks>
__host__ static inline void create_tensor_map(CUtensorMap *tma_map, bf16 *src) {
    
    constexpr uint32_t  tma_dim      = detail::st_type_2d_tma_layout<ST> ? 2 : 5; 
    void                *global_addr = reinterpret_cast<void*>(src);

    // if we're in a swizzled TMA mode, what would it be?
    constexpr CUtensorMapSwizzle      tma_swizzle_from_size = (
        ST::width == 1 ? CU_TENSOR_MAP_SWIZZLE_32B  :
        ST::width == 2 ? CU_TENSOR_MAP_SWIZZLE_64B  :
        ST::width == 4 ? CU_TENSOR_MAP_SWIZZLE_128B : 
        CUtensorMapSwizzle(-1)
    );

    constexpr CUtensorMapDataType     tma_format      = CU_TENSOR_MAP_DATA_TYPE_BFLOAT16; 
    constexpr CUtensorMapInterleave   tma_interleave  = CU_TENSOR_MAP_INTERLEAVE_NONE;
    constexpr CUtensorMapL2promotion  tma_l2Promotion = CU_TENSOR_MAP_L2_PROMOTION_NONE;
    constexpr CUtensorMapFloatOOBfill tma_oobFill     = CU_TENSOR_MAP_FLOAT_OOB_FILL_NONE;
    constexpr CUtensorMapSwizzle      tma_swizzle     = (std::is_same_v<typename ST::layout, ducks::st_layout::tma_swizzle>) ?
                                                            tma_swizzle_from_size : CU_TENSOR_MAP_SWIZZLE_NONE;

    uint64_t gmem_shape [5] = {0, 0, 0, 0, 0};
    uint64_t gmem_stride[4] = {0, 0, 0, 0};
    uint32_t smem_shape [5] = {0, 0, 0, 0, 0};
    uint32_t smem_stride[5] = {1, 1, 1, 1, 1};

    constexpr uint64_t global_tile_height = num_blocks * ST::rows;
    constexpr uint64_t global_tile_width  = ST::cols; 
    constexpr uint64_t shared_tile_height = ST::rows; 
    constexpr uint64_t shared_tile_width  = ST::cols;

    if constexpr (detail::st_type_2d_tma_layout<ST>) {
        gmem_shape[0] = global_tile_width;
        gmem_shape[1] = global_tile_height;

        gmem_stride[0] = shared_tile_width * sizeof(bf16);

        smem_shape[0] = shared_tile_width;
        smem_shape[1] = shared_tile_height;
    }
    else if constexpr (detail::st_type_wgmma_row_layout<ST>) {
        gmem_shape[0] = 8;
        gmem_shape[1] = 8;
        gmem_shape[2] = 2;
        gmem_shape[3] = global_tile_height/8;
        gmem_shape[4] = global_tile_width/16;

        gmem_stride[0] = global_tile_width * sizeof(bf16);
        gmem_stride[1] = 8 * sizeof(bf16);
        gmem_stride[2] = 8 * global_tile_width * sizeof(bf16);
        gmem_stride[3] = 16 * sizeof(bf16);

        smem_shape[0] = 8;
        smem_shape[1] = 8;
        smem_shape[2] = 2;
        smem_shape[3] = shared_tile_height/8;
        smem_shape[4] = shared_tile_width/16;
    }
    else if constexpr (detail::st_type_wgmma_col_t_layout<ST>) {
        gmem_shape[0] = 8;
        gmem_shape[1] = 8;
        gmem_shape[2] = 2;
        gmem_shape[3] = global_tile_width/8;
        gmem_shape[4] = global_tile_height/16;

        gmem_stride[0] = global_tile_width * sizeof(bf16);
        gmem_stride[1] = 8 * global_tile_width * sizeof(bf16);
        gmem_stride[2] = 8 * sizeof(bf16);
        gmem_stride[3] = 16 * global_tile_width * sizeof(bf16);

        smem_shape[0] = 8;
        smem_shape[1] = 8;
        smem_shape[2] = 2;
        smem_shape[3] = shared_tile_width/8;
        smem_shape[4] = shared_tile_height/16;
    }

    // ensure that the global address is always 16-byte aligned 
    assert((reinterpret_cast<uint64_t>(global_addr) & 0b1111) == 0);

    assert(gmem_stride[0] % 16 == 0); // gmem_stride[0] elements must be a multiple of 16B
    assert(gmem_stride[1] % 16 == 0); // gmem_stride[1] elements must be a multiple of 16B
    assert(gmem_stride[2] % 16 == 0); // gmem_stride[2] elements must be a multiple of 16B
    assert(gmem_stride[3] % 16 == 0); // gmem_stride[3] elements must be a multiple of 16B

    assert(smem_shape[0] <= 256); // smem_shape[0] elements must be <= 256
    assert(smem_shape[1] <= 256); // smem_shape[1] elements must be <= 256
    assert(smem_shape[2] <= 256); // smem_shape[2] elements must be <= 256
    assert(smem_shape[3] <= 256); // smem_shape[3] elements must be <= 256
    assert(smem_shape[4] <= 256); // smem_shape[4] elements must be <= 256

    assert(smem_shape[0] * sizeof(bf16) % 16 == 0); // if interleave is none, then smem_shape[0] * sizeof(bf16) must be a multiple of 16B

    assert(smem_stride[0] <= 8); // smem_stride[0] must be less <= 8
    assert(smem_stride[1] <= 8); // smem_stride[1] must be less <= 8
    assert(smem_stride[2] <= 8); // smem_stride[2] must be less <= 8
    assert(smem_stride[3] <= 8); // smem_stride[3] must be less <= 8
    assert(smem_stride[4] <= 8); // smem_stride[4] must be less <= 8

    assert(smem_stride[0] == 1); // smem_stride[0] is ignored when interleave is none

    if constexpr (tma_interleave == CU_TENSOR_MAP_INTERLEAVE_NONE && tma_swizzle != CU_TENSOR_MAP_SWIZZLE_NONE) {
        constexpr int swizzle_size = (ST::width) * 32;
        assert(smem_shape[0] * sizeof(bf16) <= swizzle_size);
    }

    const uint64_t *gmem_shape_ptr = &gmem_shape[0];
    const uint64_t *gmem_stride_ptr = &gmem_stride[0]; 
    const uint32_t *smem_shape_ptr = &smem_shape[0];
    const uint32_t *smem_stride_ptr = &smem_stride[0];

    CUresult result = cuTensorMapEncodeTiled(
        tma_map,
        tma_format,
        tma_dim,
        global_addr,
        gmem_shape_ptr,
        gmem_stride_ptr, 
        smem_shape_ptr,
        smem_stride_ptr,
        tma_interleave,
        tma_swizzle,
        tma_l2Promotion,
        tma_oobFill);


    const char *error_string;
    CUresult res = cuGetErrorString(result, &error_string);
    if (result != CUDA_SUCCESS) {
        std::cerr << "Error: " << error_string << std::endl;
    }
};

/* ----------   Prefetch Tensor Map  ---------- */

/**
 * @brief Prefetches data from global memory into a shared memory tile, along with the tensormap.
 *
 * @tparam ST A shared tile type with a TMA-compatible layout
 * @param[out] dst The destination shared memory tile.
 * @param[in] src_tma_map The source tensormap address in global memory
 * @param[in] tile_idx The index of the requested tile.
 */
template<detail::st_type_tma_layout ST>
__device__ static inline void prefetch(ST &dst, void const* const src_tma_map, int tile_idx) {
    if (threadIdx.x == 0) {
        uint64_t tma_ptr  = reinterpret_cast<uint64_t>(src_tma_map);

        if constexpr (detail::st_type_2d_tma_layout<ST>) {
            int32_t crd0 = 0;  
            int32_t crd1 = tile_idx * (dst.rows); 

            asm volatile (
                "cp.async.bulk.prefetch.tensor.2d.L2.global.tile"
                " [%0, {%1, %2}];"
                :
                : "l"(tma_ptr),
                "r"(crd0), "r"(crd1)
                : "memory"
            );
        }
        else {
            int32_t crd0 = 0;  
            int32_t crd1 = 0; 
            int32_t crd2 = 0;
            int32_t crd3 = detail::st_type_wgmma_row_layout<ST> ? tile_idx * (dst.rows/8) : 0;
            int32_t crd4 = detail::st_type_wgmma_row_layout<ST> ? 0 : tile_idx * (dst.rows/16);

            asm volatile (
                "cp.async.bulk.prefetch.tensor.5d.L2.global.tile"
                " [%0, {%1, %2, %3, %4, %5}];"
                :
                : "l"(tma_ptr),
                "r"(crd0), "r"(crd1), "r"(crd2), "r"(crd3), "r"(crd4)
                : "memory"
            );
        }
    }
}

/* ----------   Async load and store data from gmem/smem  ---------- */

/**
 * @brief Asynchronously stores data into global memory from a shared memory tile.
 *
 * This function performs an asynchronous copy operation using CUDA's cp.async.bulk.tensor instruction.
 *
 * @tparam ST A shared tile type with a TMA-compatible layout
 * @param[out] dst The destination tensormap address in global memory
 * @param[in] src_tma_map The source shared memory tile.
 * @param[in] tile_idx The index of the tile destination.
 */
template<detail::st_type_tma_layout ST>
__device__ static inline void store_async(void *dst_tma_map, const ST &src, int tile_idx) {
    if (::kittens::laneid() == 0) {
        uint64_t tma_ptr  = reinterpret_cast<uint64_t>(dst_tma_map);
        uint32_t src_ptr  = static_cast<uint32_t>(__cvta_generic_to_shared(&src));

        if constexpr (detail::st_type_2d_tma_layout<ST>) {
            int32_t crd0 = 0;  
            int32_t crd1 = tile_idx * (src.rows); 

            asm volatile (
                "cp.async.bulk.tensor.2d.global.shared::cta.tile.bulk_group"
                " [%0, {%2, %3}], [%1];"
                :
                : "l"(tma_ptr), "r"(src_ptr),
                "r"(crd0), "r"(crd1)
                : "memory"
            );
        }
        else {
            int32_t crd0 = 0;  
            int32_t crd1 = 0; 
            int32_t crd2 = 0;
            int32_t crd3 = detail::st_type_wgmma_row_layout<ST> ? tile_idx * (src.rows/8) : 0;
            int32_t crd4 = detail::st_type_wgmma_row_layout<ST> ? 0 : tile_idx * (src.rows/16);

            asm volatile (
                "cp.async.bulk.tensor.5d.global.shared::cta.tile.bulk_group"
                " [%0, {%2, %3, %4, %5, %6}], [%1];"
                :
                : "l"(tma_ptr), "r"(src_ptr),
                "r"(crd0), "r"(crd1), "r"(crd2), "r"(crd3), "r"(crd4)
                : "memory"
            );
        }
    }
}

/**
 * @brief Asynchronously loads data from global memory into a shared memory tile.
 *
 * This function performs an asynchronous copy operation using CUDA's cp.async.bulk.tensor instruction.
 *
 * @tparam ST A shared tile type with a TMA-compatible layout
 * @param[out] dst The destination shared memory tile.
 * @param[in] src_tma_map The source tensormap address in global memory
 * @param[in] tile_idx The index of the requested tile.
 * @param[in,out] barrier The barrier used for synchronization of the asynchronous copy.
 */
template<detail::st_type_tma_layout ST>
__device__ static inline void load_async(ST &dst, void const* const src_tma_map, int tile_idx, uint64_t& barrier) {
    if (::kittens::laneid() == 0) {
        uint64_t tma_ptr  = reinterpret_cast<uint64_t>(src_tma_map);
        uint32_t mbar_ptr = static_cast<uint32_t>(__cvta_generic_to_shared(&barrier));
        uint32_t dst_ptr  = static_cast<uint32_t>(__cvta_generic_to_shared(&dst));

        if constexpr (detail::st_type_2d_tma_layout<ST>) {
            int32_t crd0 = 0;  
            int32_t crd1 = tile_idx * (dst.rows); 

            asm volatile (
                "cp.async.bulk.tensor.2d.shared::cluster.global.tile.mbarrier::complete_tx::bytes"
                " [%0], [%1, {%3, %4}], [%2];"
                :
                : "r"(dst_ptr), "l"(tma_ptr), "r"(mbar_ptr),
                "r"(crd0), "r"(crd1)
                : "memory"
            );
        }
        else {
            int32_t crd0 = 0;  
            int32_t crd1 = 0; 
            int32_t crd2 = 0;
            int32_t crd3 = detail::st_type_wgmma_row_layout<ST> ? tile_idx * (dst.rows/8) : 0;
            int32_t crd4 = detail::st_type_wgmma_row_layout<ST> ? 0 : tile_idx * (dst.rows/16);

            asm volatile (
                "cp.async.bulk.tensor.5d.shared::cluster.global.tile.mbarrier::complete_tx::bytes"
                " [%0], [%1, {%3, %4, %5, %6, %7}], [%2];"
                :
                : "r"(dst_ptr), "l"(tma_ptr), "r"(mbar_ptr),
                "r"(crd0), "r"(crd1), "r"(crd2), "r"(crd3), "r"(crd4)
                : "memory"
            );
        }
    }
}

/* ----------   Barrier functions for async load  ---------- */

/**
* @brief Sets the number of bytes expected at the barrier.
*
* This function sets the number of bytes expected at the barrier for the first thread in the warp.
* It converts the barrier pointer to a generic shared memory pointer and uses an inline assembly
* instruction to set the expected number of bytes.
*
* @param barrier Reference to the barrier variable.
* @param bytes The number of bytes expected at the barrier.
*/
__device__ static inline void set_barrier_bytes(uint64_t& barrier, uint32_t bytes) {
    if (::kittens::laneid() == 0) {
        void const* const ptr = &barrier;
        uint32_t bar_ptr = static_cast<uint32_t>(__cvta_generic_to_shared(ptr)); 

        asm volatile ("mbarrier.arrive.expect_tx.shared::cta.b64 _, [%0], %1;\n"
            :: "r"(bar_ptr), "r"(bytes));
    }
}
/**
 * @brief Initializes a synchronization barrier with a transaction count and sets the expected number of bytes.
 *
 * This function sets up a barrier that is used to synchronize threads within a block during asynchronous operations.
 * It initializes the barrier with a thread count barrier.
 *
 * Additionally, if it is given a shared tile type, it will also call `set_barrier_bytes` to prepare for the memory transaction.
 *
 * @param[out] barrier The barrier variable to initialize.
 * @param[in] tc The thread counter for the barrier.
 */
template<typename T=ducks::default_type>
__device__ static inline void init_barrier(uint64_t& barrier, int tc) {
    static_assert(detail::st_type_tma_layout<T> || std::is_same_v<T, ducks::default_type>);
    if (::kittens::laneid() == 0) {
        void const* const ptr = &barrier;
        uint32_t bar_ptr = static_cast<uint32_t>(__cvta_generic_to_shared(ptr)); 

        asm volatile ("mbarrier.init.shared::cta.b64 [%0], %1;\n"
            :: "r"(bar_ptr), "r"(tc));

        if constexpr (detail::st_type_tma_layout<T>) {
            set_barrier_bytes(barrier, sizeof(T)); // set barrier bytes automatically
        }
    }
}

/**
* @brief Arrives at the barrier and waits for all threads to arrive.
*
* This function is used to synchronize threads at a barrier. Each thread arrives at the barrier
* and waits until all threads have arrived. The function uses inline assembly to perform the
* barrier wait operation.
*
* @param barrier Reference to the barrier variable.
* @param kPhaseBit The phase bit used for the barrier.
*/
__device__ static inline void arrive_and_wait(uint64_t& barrier, int kPhaseBit) {
    void const* const ptr = &barrier;
    uint32_t mbar_ptr = static_cast<uint32_t>(__cvta_generic_to_shared(ptr)); 

    asm volatile (
        "{\n"
        ".reg .pred                P1;\n"
        "LAB_WAIT:\n"
        "mbarrier.try_wait.parity.shared::cta.b64 P1, [%0], %1;\n"
        "@P1                       bra.uni DONE;\n"
        "bra.uni                   LAB_WAIT;\n"
        "DONE:\n"
        "}\n"
        :: "r"(mbar_ptr),
        "r"(kPhaseBit)
    );
}


/* ----------   Synchronization functions for async store  ---------- */

/**
 * @brief Commits previous asynchronous TMA stores to a group and performs them.
*/
__device__ static inline void store_commit_group() {
    if (::kittens::laneid() == 0) {
        asm volatile("cp.async.bulk.commit_group;");
    } 
}
/**
 * @brief Waits for previous committed TMA store groups to complete.
 *
 * @tparam N The maximum number of remaining TMA store groups. Defaults to 0.
*/
template <int N=0>
__device__ static inline void store_async_wait() {
    asm volatile (
        "cp.async.bulk.wait_group %0;"
        :
        : "n"(N)
        : "memory"
    );
    __syncwarp();
}

} // namespace tma
} // namespace kittens