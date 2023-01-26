/*----------------------------------------------------------------------------*/
/*  CP2K: A general program to perform molecular dynamics simulations         */
/*  Copyright 2000-2023 CP2K developers group <https://cp2k.org>              */
/*                                                                            */
/*  SPDX-License-Identifier: BSD-3-Clause                                     */
/*----------------------------------------------------------------------------*/
#ifndef DBM_MEMPOOL_H
#define DBM_MEMPOOL_H

#ifdef __cplusplus
extern "C" {
#endif

#include <stdbool.h>

/*******************************************************************************
 * \brief Internal routine for allocating host memory from the pool.
 * \author Ole Schuett
 ******************************************************************************/
void *dbm_mempool_host_malloc(const size_t size);

/*******************************************************************************
 * \brief Internal routine for allocating device memory from the pool.
 * \author Ole Schuett
 ******************************************************************************/
void *dbm_mempool_device_malloc(const size_t size);

/*******************************************************************************
 * \brief Internal routine for releasing memory back to the pool.
 * \author Ole Schuett
 ******************************************************************************/
void dbm_mempool_free(void *memory);

/*******************************************************************************
 * \brief Internal routine for freeing all memory in the pool.
 * \author Ole Schuett
 ******************************************************************************/
void dbm_mempool_clear(void);

#ifdef __cplusplus
}
#endif


/*******************************************************************************
 * \A small wrapper around malloc's to return the pointer with the typecast.
 * \author Rahul Gayatri
 ******************************************************************************/
#ifdef __cplusplus

template<class DataType>
DataType dbm_mem_alloc(size_t N)
{
  return((DataType)malloc(N));
}

template<class DataType>
DataType dbm_mem_calloc(size_t nitems, size_t N)
{
  return((DataType)calloc(nitems, N));
}

template<class DataType>
DataType dbm_mem_realloc(void* ptr, size_t N)
{
  return((DataType)realloc(ptr, N));
}

#endif

#endif

// EOF
