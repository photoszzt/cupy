import cupy
import numpy


def empty(shape, dtype=float, order='C'):
    """Returns an array without initializing the elements.

    Args:
        shape (tuple of ints): Dimensionalities of the array.
        dtype: Data type specifier.
        order ({'C', 'F'}): Row-major (C-style) or column-major
            (Fortran-style) order.

    Returns:
        cupy.ndarray: A new array with elements not initialized.

    .. seealso:: :func:`numpy.empty`

    """
    return cupy.ndarray(shape, dtype, order=order)


def _new_like_order_and_strides(a, dtype, order):
    """
    Determine order and strides as in NumPy's PyArray_NewLikeArray.

    (see: numpy/core/src/multiarray/ctors.c)
    """
    if order == 'A':
        if a.flags.f_contiguous:
            order = 'F'
        else:
            order = 'C'
    elif order == 'K':
        if a.flags.c_contiguous or a.ndim <= 1:
            order = 'C'
        elif a.flags.f_contiguous:
            order = 'F'

    if order in ['C', 'F']:
        return order, None, None

    elif order == 'K':
        """
        stable sort of strides in descending order
        axes are included so the sort will always be stable
        (mimics numpy's PyArray_CreateSortedStridePerm)
        """
        tmp = numpy.empty(len(a.strides),
                          dtype=[('strides', numpy.intp),
                                 ('axes', numpy.intp)])
        tmp['strides'] = a.strides
        tmp['axes'] = numpy.arange(a.ndim, dtype=numpy.intp)
        tmp_sorted = numpy.sort(tmp, order=['strides', 'axes'])[::-1]
        perm = tmp_sorted['axes']

        # fill in strides based on the sorted order
        order = 'C'
        stride = numpy.dtype(dtype).itemsize
        strides = numpy.zeros(a.ndim, dtype=numpy.intp)
        for idim in range(a.ndim - 1, -1, -1):
            i_perm = perm[idim]
            strides[i_perm] = stride
            stride *= a.shape[i_perm]

        memptr = cupy.empty(a.size, dtype=dtype).data
        return order, strides, memptr
    else:
        raise TypeError('order not understood: {}'.format(order))


def empty_like(a, dtype=None, order='K'):
    """Returns a new array with same shape and dtype of a given array.

    This function currently does not support ``order`` and ``subok`` options.

    Args:
        a (cupy.ndarray): Base array.
        dtype: Data type specifier. The data type of ``a`` is used by default.
        order ({'C', 'F', 'A', or 'K'}): Overrides the memory layout of the
            result. 'C' means C-order, 'F' means F-order, 'A' means 'F' if
            ``a`` is Fortran contiguous, 'C' otherwise. 'K' means match the
            layout of ``a`` as closely as possible.

    Returns:
        cupy.ndarray: A new array with same shape and dtype of ``a`` with
        elements not initialized.

    .. seealso:: :func:`numpy.empty_like`

    """
    if dtype is None:
        dtype = a.dtype

    order, strides, memptr = _new_like_order_and_strides(a, dtype, order)
    return cupy.ndarray(a.shape, dtype, memptr, strides, order)


def eye(N, M=None, k=0, dtype=float):
    """Returns a 2-D array with ones on the diagonals and zeros elsewhere.

    Args:
        N (int): Number of rows.
        M (int): Number of columns. M == N by default.
        k (int): Index of the diagonal. Zero indicates the main diagonal,
            a positive index an upper diagonal, and a negative index a lower
            diagonal.
        dtype: Data type specifier.

    Returns:
        cupy.ndarray: A 2-D array with given diagonals filled with ones and
        zeros elsewhere.

    .. seealso:: :func:`numpy.eye`

    """
    if M is None:
        M = N
    ret = zeros((N, M), dtype)
    ret.diagonal(k)[:] = 1
    return ret


def identity(n, dtype=float):
    """Returns a 2-D identity array.

    It is equivalent to ``eye(n, n, dtype)``.

    Args:
        n (int): Number of rows and columns.
        dtype: Data type specifier.

    Returns:
        cupy.ndarray: A 2-D identity array.

    .. seealso:: :func:`numpy.identity`

    """
    return eye(n, dtype=dtype)


def ones(shape, dtype=float):
    """Returns a new array of given shape and dtype, filled with ones.

    This function currently does not support ``order`` option.

    Args:
        shape (tuple of ints): Dimensionalities of the array.
        dtype: Data type specifier.

    Returns:
        cupy.ndarray: An array filled with ones.

    .. seealso:: :func:`numpy.ones`

    """
    # TODO(beam2d): Support ordering option
    a = cupy.ndarray(shape, dtype)
    a.fill(1)
    return a


def ones_like(a, dtype=None, order='K'):
    """Returns an array of ones with same shape and dtype as a given array.

    This function currently does not support ``order`` and ``subok`` options.

    Args:
        a (cupy.ndarray): Base array.
        dtype: Data type specifier. The dtype of ``a`` is used by default.
        order ({'C', 'F', 'A', or 'K'}): Overrides the memory layout of the
            result. 'C' means C-order, 'F' means F-order, 'A' means 'F' if
            ``a`` is Fortran contiguous, 'C' otherwise. 'K' means match the
            layout of ``a`` as closely as possible.

    Returns:
        cupy.ndarray: An array filled with ones.

    .. seealso:: :func:`numpy.ones_like`

    """
    if dtype is None:
        dtype = a.dtype
    order, strides, memptr = _new_like_order_and_strides(a, dtype, order)
    a = cupy.ndarray(a.shape, dtype, memptr, strides, order)
    a.fill(1)
    return a


def zeros(shape, dtype=float, order='C'):
    """Returns a new array of given shape and dtype, filled with zeros.

    Args:
        shape (tuple of ints): Dimensionalities of the array.
        dtype: Data type specifier.
        order ({'C', 'F'}): Row-major (C-style) or column-major
            (Fortran-style) order.

    Returns:
        cupy.ndarray: An array filled with zeros.

    .. seealso:: :func:`numpy.zeros`

    """
    a = cupy.ndarray(shape, dtype, order=order)
    a.data.memset_async(0, a.nbytes)
    return a


def zeros_like(a, dtype=None, order='K'):
    """Returns an array of zeros with same shape and dtype as a given array.

    This function currently does not support ``order`` and ``subok`` options.

    Args:
        a (cupy.ndarray): Base array.
        dtype: Data type specifier. The dtype of ``a`` is used by default.
        order ({'C', 'F', 'A', or 'K'}): Overrides the memory layout of the
            result. 'C' means C-order, 'F' means F-order, 'A' means 'F' if
            ``a`` is Fortran contiguous, 'C' otherwise. 'K' means match the
            layout of ``a`` as closely as possible.\

    Returns:
        cupy.ndarray: An array filled with zeros.

    .. seealso:: :func:`numpy.zeros_like`

    """
    if dtype is None:
        dtype = a.dtype
    order, strides, memptr = _new_like_order_and_strides(a, dtype, order)
    a = cupy.ndarray(a.shape, dtype, memptr, strides, order)
    a.data.memset_async(0, a.nbytes)
    return a


def full(shape, fill_value, dtype=None):
    """Returns a new array of given shape and dtype, filled with a given value.

    This function currently does not support ``order`` option.

    Args:
        shape (tuple of ints): Dimensionalities of the array.
        fill_value: A scalar value to fill a new array.
        dtype: Data type specifier.

    Returns:
        cupy.ndarray: An array filled with ``fill_value``.

    .. seealso:: :func:`numpy.full`

    """
    # TODO(beam2d): Support ordering option
    if dtype is None:
        if isinstance(fill_value, cupy.ndarray):
            dtype = fill_value.dtype
        else:
            dtype = numpy.array(fill_value).dtype
    a = cupy.ndarray(shape, dtype)
    a.fill(fill_value)
    return a


def full_like(a, fill_value, dtype=None, order='K'):
    """Returns a full array with same shape and dtype as a given array.

    This function currently does not support ``order`` and ``subok`` options.

    Args:
        a (cupy.ndarray): Base array.
        fill_value: A scalar value to fill a new array.
        dtype: Data type specifier. The dtype of ``a`` is used by default.
        order ({'C', 'F', 'A', or 'K'}): Overrides the memory layout of the
            result. 'C' means C-order, 'F' means F-order, 'A' means 'F' if
            ``a`` is Fortran contiguous, 'C' otherwise. 'K' means match the
            layout of ``a`` as closely as possible.

    Returns:
        cupy.ndarray: An array filled with ``fill_value``.

    .. seealso:: :func:`numpy.full_like`

    """
    if dtype is None:
        dtype = a.dtype
    order, strides, memptr = _new_like_order_and_strides(a, dtype, order)
    a = cupy.ndarray(a.shape, dtype, memptr, strides, order)
    a.fill(fill_value)
    return a
