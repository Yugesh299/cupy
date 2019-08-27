from cpython.mem cimport PyMem_Malloc, PyMem_Free
from libc.stdint cimport intptr_t
from libc.string cimport memset as c_memset

import numpy

import cupy
from cupy.cuda cimport device
from cupy.cuda cimport runtime
from cupy.cuda.memory cimport BaseMemory



cdef class CUDAArray(BaseMemory):
    # TODO(leofang): perhaps this wrapper is not needed when cupy.ndarray
    # can be backed by texture memory/CUDA arrays?
    def __init__(self, runtime.ChannelFormatDescriptor desc, size_t width,
                 size_t height, size_t depth=0, unsigned int flags=0):
        self.device_id = device.get_device_id()

        if width == 0:
            raise ValueError('To create a CUDA array, width must be nonzero.')
        elif height == 0 and depth > 0:
            raise ValueError
        else:
            self.ptr = runtime.malloc3DArray(desc.ptr, width, height, depth,
                                             flags)

        # bookkeeping
        self.desc = desc
        self.width = width
        self.height = height
        self.depth = depth
        self.flags = flags
        if self.depth > 0:
            self.ndim = 3
        elif self.height > 0:
            self.ndim = 2
        else:
            self.ndim = 1

    def __dealloc__(self):
        if self.ptr:
            runtime.freeArray(self.ptr)
            self.ptr = 0

    cdef runtime.Memcpy3DParms* _make_cudaMemcpy3DParms(self, src, dst):
        cdef runtime.Memcpy3DParms* param = \
            <runtime.Memcpy3DParms*>PyMem_Malloc(sizeof(runtime.Memcpy3DParms))
        c_memset(param, 0, sizeof(runtime.Memcpy3DParms))
        cdef runtime.PitchedPtr srcPitchedPtr, dstPitchedPtr
        cdef intptr_t ptr 

        # get kind
        if isinstance(src, cupy.core.core.ndarray) and dst is self:
            param.kind = <runtime.MemoryKind>runtime.memcpyDeviceToDevice
        elif src is self and isinstance(dst, cupy.core.core.ndarray):
            param.kind = <runtime.MemoryKind>runtime.memcpyDeviceToDevice
        elif isinstance(src, numpy.ndarray) and dst is self:
            param.kind = <runtime.MemoryKind>runtime.memcpyHostToDevice
        elif src is self and isinstance(dst, numpy.ndarray):
            param.kind = <runtime.MemoryKind>runtime.memcpyDeviceToHost
        else:
            raise

        # get src
        if src is self:
            # Important: cannot convert from src.ptr!
            param.srcArray = <runtime.Array>(self.ptr)
            param.extent = runtime.make_Extent(self.width, self.height,
                                               self.depth)
        else:
            width = src.shape[-1]
            if src.ndim >= 2:
                height = src.shape[-2]
            else:
                height = 0

            if isinstance(src, cupy.core.core.ndarray):
                ptr = src.data.ptr
            else:  # numpy.ndarray
                ptr = src.ctypes.data

            srcPitchedPtr = runtime.make_PitchedPtr(
                ptr, width*src.dtype.itemsize, width, height)
            param.srcPtr = srcPitchedPtr

        # get dst
        if dst is self:
            # Important: cannot convert from dst.ptr!
            param.dstArray = <runtime.Array>(self.ptr)
            param.extent = runtime.make_Extent(self.width, self.height,
                                               self.depth)
        else:
            width = dst.shape[-1]
            if dst.ndim >= 2:
                height = dst.shape[-2]
            else:
                height = 0

            if isinstance(dst, cupy.core.core.ndarray):
                ptr = dst.data.ptr
            else:  # numpy.ndarray
                ptr = dst.ctypes.data

            dstPitchedPtr = runtime.make_PitchedPtr(
                ptr, width*dst.dtype.itemsize, width, height)
            param.dstPtr = dstPitchedPtr

        return param

    def _prepare_copy(self, arr, stream, direction):
        '''
        Args:
            arr (cupy.core.core.ndarray or numpy.ndarray)
            stream (cupy.cuda.Stream)
            direction (str)
        '''
        # sanity checks:
        # - check shape
        if self.ndim == 3:
            if arr.shape != (self.depth, self.height, self.width):
                raise ValueError
        elif self.ndim == 2:
            if arr.shape != (self.height, self.width):
                raise ValueError
        else:  # ndim = 1
            if arr.shape != (self.width,):
                raise ValueError

        # - check dtype
        # TODO(leofang): support signed and unsigned
        if arr.dtype != numpy.float32:
            raise ValueError

        cdef runtime.Memcpy3DParms* param

        if self.ndim == 3:
            if direction == 'in':
                param = self._make_cudaMemcpy3DParms(arr, self)
            elif direction == 'out':
                param = self._make_cudaMemcpy3DParms(self, arr)
            try:
                if stream is None:
                    runtime.memcpy3D(<intptr_t>param)
                else:
                    runtime.memcpy3DAsync(<intptr_t>param, stream.ptr)
            except:
                raise
            finally:
                PyMem_Free(param)
        else:
            raise NotImplementedError

    cdef _print_param(self, runtime.Memcpy3DParms* param):
        cdef runtime.Array ptr
        ptr = param.srcArray
        print(<intptr_t>(ptr))
        print(param.srcPos.x, param.srcPos.y, param.srcPos.z)
        print(<intptr_t>param.srcPtr.ptr, param.srcPtr.pitch, param.srcPtr.xsize, param.srcPtr.ysize)
        
        ptr = param.dstArray
        print(<intptr_t>ptr)
        print(param.dstPos.x, param.dstPos.y, param.dstPos.z)
        print(<intptr_t>param.dstPtr.ptr, param.dstPtr.pitch, param.dstPtr.xsize, param.dstPtr.ysize)

        print(param.extent.width, param.extent.height, param.extent.depth)
        print(param.kind)

        ptr = <runtime.Array>self.ptr
        print(self.ptr, <intptr_t>ptr)
        print('\n', flush=True)

    def copy_from(self, in_arr, stream=None):
        self._prepare_copy(in_arr, stream, direction='in')

    def copy_to(self, out_arr, stream=None):
        self._prepare_copy(out_arr, stream, direction='out')


cdef class TextureObject:
    # GOAL: make this pass-able to RawKernel
    def __init__(self, runtime.ResourceDescriptor ResDesc,
                 runtime.TextureDescriptor TexDesc):
        self.ptr = runtime.createTextureObject(ResDesc.ptr, TexDesc.ptr)
        
    def __dealloc__(self):
        if self.ptr:
            runtime.destroyTextureObject(self.ptr)
            self.ptr = 0
