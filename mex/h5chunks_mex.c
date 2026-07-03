/* h5chunks_mex.c - expose H5Dget_num_chunks / H5Dget_chunk_info, which the
 * HDF5 1.10.5+ C library has but MATLAB's m-code wrappers do not.
 *
 *   [addr, size, filterMask, offsets] = h5chunks_mex(int64(dsetId), rank)
 *
 * addr/size: nchunks x 1 uint64; filterMask: nchunks x 1 uint32;
 * offsets: nchunks x rank uint64 (as returned by the C API, i.e. file/C order).
 *
 * Linked against MATLAB's own bundled libhdf5, so ids from H5D.open work.
 */
#include <stdint.h>
#include "mex.h"

typedef int64_t hid_t;
typedef unsigned long long hsize_t;
typedef unsigned long long haddr_t;
typedef int herr_t;
#define H5S_ALL_ID ((hid_t)0)

extern herr_t H5Dget_num_chunks(hid_t dset_id, hid_t fspace_id, hsize_t *nchunks);
extern herr_t H5Dget_chunk_info(hid_t dset_id, hid_t fspace_id, hsize_t chk_idx,
                                hsize_t *offset, unsigned *filter_mask,
                                haddr_t *addr, hsize_t *size);
extern int H5Iis_valid(hid_t id);
extern hsize_t H5Dget_storage_size(hid_t dset_id);

void mexFunction(int nlhs, mxArray *plhs[], int nrhs, const mxArray *prhs[])
{
    (void)nlhs;
    if (nrhs < 2 || !mxIsInt64(prhs[0]))
        mexErrMsgIdAndTxt("matzarr:usage",
                          "usage: h5chunks_mex(int64(dsetId), rank[, int64(fspaceId)])");
    hid_t dset = *(int64_t *)mxGetData(prhs[0]);
    hid_t fspace = H5S_ALL_ID;
    if (nrhs > 2 && mxIsInt64(prhs[2]))
        fspace = *(int64_t *)mxGetData(prhs[2]);
    
    int rank = (int)mxGetScalar(prhs[1]);
    if (rank < 1 || rank > 32)
        mexErrMsgIdAndTxt("matzarr:usage", "rank out of range");

    hsize_t n = 0;
    if (H5Dget_num_chunks(dset, fspace, &n) < 0)
        mexErrMsgIdAndTxt("matzarr:h5", "H5Dget_num_chunks failed");

    plhs[0] = mxCreateNumericMatrix((mwSize)n, 1, mxUINT64_CLASS, mxREAL);
    plhs[1] = mxCreateNumericMatrix((mwSize)n, 1, mxUINT64_CLASS, mxREAL);
    plhs[2] = mxCreateNumericMatrix((mwSize)n, 1, mxUINT32_CLASS, mxREAL);
    plhs[3] = mxCreateNumericMatrix((mwSize)n, (mwSize)rank, mxUINT64_CLASS, mxREAL);
    uint64_t *addr = (uint64_t *)mxGetData(plhs[0]);
    uint64_t *size = (uint64_t *)mxGetData(plhs[1]);
    uint32_t *filt = (uint32_t *)mxGetData(plhs[2]);
    uint64_t *offs = (uint64_t *)mxGetData(plhs[3]);

    for (hsize_t k = 0; k < n; k++) {
        hsize_t off[32];
        unsigned fm = 0;
        haddr_t a = 0;
        hsize_t sz = 0;
        if (H5Dget_chunk_info(dset, fspace, k, off, &fm, &a, &sz) < 0)
            mexErrMsgIdAndTxt("matzarr:h5", "H5Dget_chunk_info failed at %llu", k);
        addr[k] = (uint64_t)a;
        size[k] = (uint64_t)sz;
        filt[k] = (uint32_t)fm;
        for (int d = 0; d < rank; d++)
            offs[k + (hsize_t)d * n] = (uint64_t)off[d];  /* column d */
    }
}
