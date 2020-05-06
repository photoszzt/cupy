import cupy
from cupy import util
from cupy.cuda cimport driver
from cupy.cuda cimport runtime
from cupy.cuda.function cimport Function, Module


cdef class RawKernel:

    """User-defined custom kernel.

    This class can be used to define a custom kernel using raw CUDA source.

    The kernel is compiled at an invocation of the :meth:`~RawKernel.__call__`
    method, which is cached for each device.
    The compiled binary is also cached into a file under the
    ``$HOME/.cupy/kernel_cache/`` directory with a hashed file name. The cached
    binary is reused by other processes.

    Args:
        code (str): CUDA source code.
        name (str): Name of the kernel function.
        options (tuple of str): Compiler options passed to the backend (NVRTC
            or NVCC). For details, see
            https://docs.nvidia.com/cuda/nvrtc/index.html#group__options or
            https://docs.nvidia.com/cuda/cuda-compiler-driver-nvcc/index.html#command-option-description
        backend (str): Either `nvrtc` or `nvcc`. Defaults to `nvrtc`
        translate_cucomplex (bool): Whether the CUDA source includes the header
            `cuComplex.h` or not. If set to ``True``, any code that uses the
            functions from `cuComplex.h` will be translated to its Thrust
            counterpart. Defaults to ``False``.
        enable_cooperative_groups (bool): Whether to enable cooperative groups
            in the CUDA source. If set to ``True``, compile options are
            configured properly and the kernel is launched with
            ``cuLaunchCooperativeKernel`` so that cooperative groups can be
            used from the CUDA source.
            This feature is only supported in CUDA 9 or later.
    """

    def __init__(self, str code, str name, tuple options=(),
                 str backend='nvrtc', *, bint translate_cucomplex=False,
                 bint enable_cooperative_groups=False):

        self.code = code
        self.name = name
        self.options = options
        self.backend = backend
        self.translate_cucomplex = translate_cucomplex
        self.enable_cooperative_groups = enable_cooperative_groups

        # only used when RawKernels are produced from RawModule
        self.file_path = None  # for cubin/ptx
        self.specializations = None  # for C++ template

    def __call__(self, grid, block, args, **kwargs):
        """__call__(self, grid, block, args, *, shared_mem=0)

        Compiles and invokes the kernel.

        The compilation runs only if the kernel is not cached.

        Args:
            grid (tuple): Size of grid in blocks.
            block (tuple): Dimensions of each thread block.
            args (tuple): Arguments of the kernel.
            shared_mem (int): Dynamic shared-memory size per thread block in
                bytes.

        """
        self.kernel(
            grid, block, args,
            enable_cooperative_groups=self.enable_cooperative_groups,
            **kwargs)

    @property
    def kernel(self):
        # The kernel is cached, so on the device where this has been called,
        # we would just look up from the cache, and do recompiling only when
        # switching to a different device
        cdef Function ker
        ker = _get_raw_kernel(
            self.code, self.file_path, self.name, self.options, self.backend,
            self.translate_cucomplex, self.enable_cooperative_groups,
            self.specializations)
        return ker

    @property
    def attributes(self):
        """Returns a dictionary containing runtime kernel attributes. This is
        a read-only property; to overwrite the attributes, use

        .. code-block:: python

            kernel = RawKernel(...)  # arguments omitted
            kernel.max_dynamic_shared_size_bytes = ...
            kernel.preferred_shared_memory_carveout = ...

        Note that the two attributes shown in the above example are the only
        two currently settable in CUDA.

        Any attribute not existing in the present CUDA toolkit version will
        have the value -1.

        Returns:
            dict: A dictionary containing the kernel's attributes.
        """
        cdef dict attrs = {}
        cdef list keys = ['max_threads_per_block', 'shared_size_bytes',
                          'const_size_bytes', 'local_size_bytes',
                          'num_regs', 'ptx_version', 'binary_version',
                          'cache_mode_ca', 'max_dynamic_shared_size_bytes',
                          'preferred_shared_memory_carveout']
        for attr in keys:
            attrs[attr] = getattr(self, attr)
        return attrs

    @property
    def max_threads_per_block(self):
        """The maximum number of threads per block that can successfully
        launch the function on the device.
        """
        attr = driver.CU_FUNC_ATTRIBUTE_MAX_THREADS_PER_BLOCK
        return driver.funcGetAttribute(attr, self.kernel.ptr)

    @property
    def shared_size_bytes(self):
        """The size in bytes of the statically-allocated shared memory
        used by the function. This is separate from any dynamically-allocated
        shared memory, which must be specified when the function is called.
        """
        attr = driver.CU_FUNC_ATTRIBUTE_SHARED_SIZE_BYTES
        return driver.funcGetAttribute(attr, self.kernel.ptr)

    @property
    def const_size_bytes(self):
        """The size in bytes of constant memory used by the function."""
        attr = driver.CU_FUNC_ATTRIBUTE_CONST_SIZE_BYTES
        return driver.funcGetAttribute(attr, self.kernel.ptr)

    @property
    def local_size_bytes(self):
        """The size in bytes of local memory used by the function."""
        attr = driver.CU_FUNC_ATTRIBUTE_LOCAL_SIZE_BYTES
        return driver.funcGetAttribute(attr, self.kernel.ptr)

    @property
    def num_regs(self):
        """The number of registers used by the function."""
        attr = driver.CU_FUNC_ATTRIBUTE_NUM_REGS
        return driver.funcGetAttribute(attr, self.kernel.ptr)

    @property
    def ptx_version(self):
        """The PTX virtual architecture version that was used during
        compilation, in the format: 10*major + minor.
        """
        attr = driver.CU_FUNC_ATTRIBUTE_PTX_VERSION
        return driver.funcGetAttribute(attr, self.kernel.ptr)

    @property
    def binary_version(self):
        """The binary architecture version that was used during compilation,
        in the format: 10*major + minor.
        """
        attr = driver.CU_FUNC_ATTRIBUTE_BINARY_VERSION
        return driver.funcGetAttribute(attr, self.kernel.ptr)

    @property
    def cache_mode_ca(self):
        """Indicates whether option "-Xptxas --dlcm=ca" was set during
        compilation.
        """
        attr = driver.CU_FUNC_ATTRIBUTE_CACHE_MODE_CA
        return driver.funcGetAttribute(attr, self.kernel.ptr)

    @property
    def max_dynamic_shared_size_bytes(self):
        """The maximum dynamically-allocated shared memory size in bytes that
        can be used by the function. Can be set.
        """
        attr = driver.CU_FUNC_ATTRIBUTE_MAX_DYNAMIC_SHARED_SIZE_BYTES
        return driver.funcGetAttribute(attr, self.kernel.ptr)

    @max_dynamic_shared_size_bytes.setter
    def max_dynamic_shared_size_bytes(self, bytes):
        attr = driver.CU_FUNC_ATTRIBUTE_MAX_DYNAMIC_SHARED_SIZE_BYTES
        driver.funcSetAttribute(self.kernel.ptr, attr, bytes)

    @property
    def preferred_shared_memory_carveout(self):
        """On devices that have a unified L1 cache and shared memory,
        indicates the fraction to be used for shared memory as a
        `percentage` of the total. If the fraction does not exactly equal a
        supported shared memory capacity, then the next larger supported
        capacity is used. Can be set.
        """
        attr = driver.CU_FUNC_ATTRIBUTE_PREFERRED_SHARED_MEMORY_CARVEOUT
        return driver.funcGetAttribute(attr, self.kernel.ptr)

    @preferred_shared_memory_carveout.setter
    def preferred_shared_memory_carveout(self, fraction):
        attr = driver.CU_FUNC_ATTRIBUTE_PREFERRED_SHARED_MEMORY_CARVEOUT
        driver.funcSetAttribute(self.kernel.ptr, attr, fraction)


@cupy.util.memoize(for_each_device=True)
def _get_raw_kernel(str code, str path, str name, tuple options=(),
                    str backend='nvrtc',
                    bint translate_cucomplex=False,
                    bint enable_cooperative_groups=False,
                    tuple specializations=None):
    cdef Module mod
    cdef Function ker
    assert (code is None) != (path is None)
    mod = _get_raw_module(code, path, options, backend,
                          translate_cucomplex, enable_cooperative_groups,
                          specializations)
    ker = mod.get_function(name)
    return ker


cdef class RawModule:
    """User-defined custom module.

    This class can be used to either compile raw CUDA sources or load CUDA
    modules (\\*.cubin, \\*.ptx). This class is useful when a number of CUDA
    kernels in the same source need to be retrieved.

    For the former case, the CUDA source code is compiled when initializing a
    new instance of this class, and the kernels can be retrieved by calling
    :meth:`get_function`, which will return an instance of :class:`RawKernel`.
    (Same as in :class:`RawKernel`, the generated binary is also cached.)

    For the latter case, an existing CUDA binary (\\*.cubin) or a PTX file can
    be loaded by providing its path, and kernels therein can be retrieved
    similarly.

    Args:
        code (str): CUDA source code. Mutually exclusive with ``path``.
        path (str): Path to cubin/ptx. Mutually exclusive with ``code``.
        options (tuple of str): Compiler options passed to the backend (NVRTC
            or NVCC). For details, see
            https://docs.nvidia.com/cuda/nvrtc/index.html#group__options or
            https://docs.nvidia.com/cuda/cuda-compiler-driver-nvcc/index.html#command-option-description
        backend (str): Either `nvrtc` or `nvcc`. Defaults to `nvrtc`
        translate_cucomplex (bool): Whether the CUDA source includes the header
            `cuComplex.h` or not. If set to ``True``, any code that uses the
            functions from `cuComplex.h` will be translated to its Thrust
            counterpart. Defaults to ``False``.
        enable_cooperative_groups (bool): Whether to enable cooperative groups
            in the CUDA source. If set to ``True``, compile options are
            configured properly and the kernel is launched with
            ``cuLaunchCooperativeKernel`` so that cooperative groups can be
            used from the CUDA source.
            This feature is only supported in CUDA 9 or later.
        specializations (tuple of str): A tuple of strings for specializing
            C++ template kernels. For example, ``specializations=('func<int>',
            'func<double>')`` for the template kernel ``func<T>``. Strings in
            this tuple must then be passed, one at a time, to
            :meth:`get_mangled_name` to retrieve the corresponding kernel name.

    .. note::
        Each kernel in ``RawModule`` possesses independent function attributes.
    """
    def __init__(self, *, str code=None, str path=None, tuple options=(),
                 str backend='nvrtc', bint translate_cucomplex=False,
                 bint enable_cooperative_groups=False,
                 tuple specializations=None):
        if (code is None) == (path is None):
            raise TypeError(
                'Exactly one of `code` and `path` keyword arguments must be '
                'given.')
        if specializations:
            if code is None:
                raise ValueError('need template code for the requested '
                                 'specializations')
            if backend != 'nvrtc':
                raise ValueError('only nvrtc supports retrieving the mangled '
                                 'names for template specializations')
            for option in options:
                if '-std=c++' in option:  # both -std and --std are valid
                    break
            else:
                raise ValueError('need to specify C++ standard for compiling '
                                 'template code')

        self.code = code
        self.file_path = path
        self.enable_cooperative_groups = enable_cooperative_groups
        self.specializations = specializations

        if self.code is not None:
            self.options = options
            self.backend = backend
            self.translate_cucomplex = translate_cucomplex
        elif self.file_path is not None:
            self.options = ()
            self.backend = 'nvcc'
            self.translate_cucomplex = False

        # trigger compiling or loading
        cdef Module mod = self.module  # noqa

    @property
    def module(self):
        # The module is cached, so on the device where this has been called,
        # we would just look up from the cache, and do recompiling only when
        # switching to a different device
        cdef Module mod
        mod = _get_raw_module(
            self.code, self.file_path, self.options, self.backend,
            self.translate_cucomplex, self.enable_cooperative_groups,
            self.specializations)
        return mod

    def get_function(self, str name):
        """Retrieve a CUDA kernel by its name from the module.

        Args:
            name (str): Name of the kernel function.

        Returns:
            RawKernel: An ``RawKernel`` instance.

        .. note::
            For C++ template kernels, the argument ``name`` can be retrieved
            by calling :meth:`get_mangled_name`.

        """
        cdef RawKernel ker
        cdef Function func
        ker = RawKernel(
            self.code, name, self.options, self.backend,
            translate_cucomplex=self.translate_cucomplex,
            enable_cooperative_groups=self.enable_cooperative_groups)
        # for lookup in case we loaded from cubin/ptx
        ker.file_path = self.file_path
        # for lookup in case we specialize a template
        ker.specializations = self.specializations
        # register the kernel in the cache.
        func = ker.kernel  # noqa
        return ker

    def get_texref(self, name):
        '''Retrieve a texture reference by its name from the module.

        Args:
            name (str): Name of the texture reference.

        Returns:
            intptr_t: A ``CUtexref`` handle, to be passed to :class:`~cupy.cuda.texture.TextureReference`.
        '''  # noqa
        return self.module.get_texref(name)

    def get_global(self, name):
        '''Retrieve a pointer to a global symbol by its name from the module.

        Args:
            name (str): Name of the global symbol.

        Returns:
            ~cupy.cuda.MemoryPointer: A handle to the global symbol.

        .. note::
            This method can be used to access, for example, constant memory:

            .. code-block:: python

                # to get a pointer to "arr" declared in the source like this:
                # __constant__ float arr[10];
                memptr = mod.get_global("arr")
                # ...wrap it using cupy.ndarray with a known shape
                arr_ndarray = cp.ndarray((10,), cp.float32, memptr)
                # ...perform data transfer to initialize it
                arr_ndarray[...] = cp.random.random((10,), dtype=cp.float32)
                # ...and arr is ready to be accessed by RawKernels

        '''
        from cupy.cuda.memory import MemoryPointer, UnownedMemory
        cdef Module mod = self.module
        ptr = mod.get_global_var(name)
        # unable to retrieve size, plus it's not used anywhere, so just put 0
        mem = UnownedMemory(ptr, 0, mod)
        memptr = MemoryPointer(mem, 0)
        return memptr

    def get_mangled_name(self, str kernel):
        """Get the mangled name for C++ template kernel

        Args:
            kernel (str): the template specialization used when initializing
                the present RawModule instance.

        Returns:
            str: the corresponding mangled name that can be passed to
                :meth:`get_function` for retrieving the kernel

        .. note::
            The following example shows how to retrieve one of the specialized
            C++ template kernels:

            .. code-block:: python

                code = r'''
                template<typename T>
                __global__ void func(T* in_arr) { /* do something */ }
                '''

                kers = ('func<int>', 'func<float>', 'func<double>')
                mod = cupy.RawModule(code=code, options=('--std=c++11',),
                                     specializations=kers)
                // retrieve func<int>
                ker = kers[0]
                ker_name_int = mod.get_mangled_name(ker)
                ker_int = mod.get_function(ker_name_int)

        .. seealso::
            ``nvrtcAddNameExpression`` and ``nvrtcGetLoweredName`` from
            `Accessing Lowered Names`_ of the NVRTC documentation.

        .. _Accessing Lowered Names:
            https://docs.nvidia.com/cuda/nvrtc/index.html#accessing-lowered-names
        """
        if not self.specializations:
            raise RuntimeError('The module was not compiled with any template '
                               'specialization specified.')
        if kernel not in self.specializations:
            raise ValueError('The kernel ' + kernel + ' was not specialized.')
        return self.module.mapping[kernel]


@cupy.util.memoize(for_each_device=True)
def _get_raw_module(str code, str path, tuple options=(), str backend='nvrtc',
                    bint translate_cucomplex=False,
                    bint enable_cooperative_groups=False,
                    tuple specializations=None):
    cdef Module mod
    if code is not None:
        mod = cupy.core.core.compile_with_cache(
            code, options, prepend_cupy_headers=False, backend=backend,
            translate_cucomplex=translate_cucomplex,
            enable_cooperative_groups=enable_cooperative_groups,
            specializations=specializations)
    elif path is not None:
        mod = Module()
        mod.load_file(path)
    return mod
