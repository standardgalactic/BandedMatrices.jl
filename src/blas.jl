# We implement for pointers

import Base.BLAS: blasfunc,libblas,BlasInt

for (fname, elty) in ((:dgbmv_,:Float64),
                      (:sgbmv_,:Float32),
                      (:zgbmv_,:Complex128),
                      (:cgbmv_,:Complex64))
    @eval begin
             # SUBROUTINE DGBMV(TRANS,M,N,KL,KU,ALPHA,A,LDA,X,INCX,BETA,Y,INCY)
             # *     .. Scalar Arguments ..
             #       DOUBLE PRECISION ALPHA,BETA
             #       INTEGER INCX,INCY,KL,KU,LDA,M,N
             #       CHARACTER TRANS
             # *     .. Array Arguments ..
             #       DOUBLE PRECISION A(LDA,*),X(*),Y(*)
        function gbmv!(trans::Char, m::Integer, kl::Integer, ku::Integer, alpha::($elty), A::Ptr{$elty}, n::Integer, st::Integer, x::Ptr{$elty}, beta::($elty), y::Ptr{$elty})
            ccall(($(blasfunc(fname)), libblas), Void,
                (Ptr{UInt8}, Ptr{BlasInt}, Ptr{BlasInt}, Ptr{BlasInt},
                 Ptr{BlasInt}, Ptr{$elty}, Ptr{$elty}, Ptr{BlasInt},
                 Ptr{$elty}, Ptr{BlasInt}, Ptr{$elty}, Ptr{$elty},
                 Ptr{BlasInt}),
                 &trans, &m, &n, &kl,
                 &ku, &alpha, A, &st,
                 x, &1, &beta, y, &1)
            y
        end
    end
end


# this is matrix*matrix

gbmm!{T}(α,A::BandedMatrix,B::BandedMatrix,β,C::BandedMatrix{T})=gbmm!(convert(T,α),
                                                                       convert(BandedMatrix{T},A),
                                                                       convert(BandedMatrix{T},B),
                                                                       convert(T,β),
                                                                       C)

function gbmm!{T}(α::T,A::BandedMatrix{T},B::BandedMatrix{T},β,C::BandedMatrix{T})
    n,ν=size(A)
    m=size(B,2)

    @assert n==size(C,1)
    @assert ν==size(B,1)
    @assert m==size(C,2)


    a=pointer(A.data)
    b=pointer(B.data)
    c=pointer(C.data)
    sta=max(1,stride(A.data,2))
    stb=max(1,stride(B.data,2))
    stc=max(1,stride(C.data,2))
    sz=sizeof(T)

    #TODO: The following redoes columns in degenerate cases

    # Multiply columns j where B[1,j]≠0: A is at 1,1 and C[1,j]≠0
    for j=1:min(B.u+1,m)
        gbmv!('N',min(C.l+j,n), A.l, A.u, α, a, min(B.l+j,ν), sta, b+sz*((j-1)*stb+B.u-j+1), β, c+sz*((j-1)*stc+C.u-j+1))
    end
    # Multiply columns j where B[k,j]=0 for k<p=(j-B.u-1), A is at 1,1+p and C[1,j]≠0
    # j ≤ ν + B.u since then 1+p ≤ ν, so inside the columns of A
    for j=B.u+2:min(C.u+1,m,ν+B.u)
        p=j-B.u-1
        gbmv!('N', min(C.l+j,n), A.l+p, A.u-p, α, a+sz*p*sta, min(B.l+B.u+1,ν-p), sta, b+sz*(j-1)*stb, β, c+sz*((j-1)*stc+C.u-j+1))
    end

    # multiply columns where A, B and C are mid
    for j=C.u+2:min(n-C.l,m,ν+B.u)
        gbmv!('N', C.l+C.u+1, A.l+A.u, 0, α, a+sz*(j-B.u-1)*sta, B.l+B.u+1, sta, b+sz*(j-1)*stb, β, c+sz*(j-1)*stc)
    end

    # multiply columns where A and B are mid and C is bottom
    for j=max(n-C.l+1,C.u+1):min(ν-B.l,n+C.u,m)
        gbmv!('N', n-j+C.u+1, A.l+A.u, 0, α, a+sz*(j-B.u-1)*sta, B.l+B.u+1, sta, b+sz*(j-1)*stb, β, c+sz*(j-1)*stc)
    end

    # multiply columns where A,  B and C are bottom
    for j=max(ν-B.l+1,C.u+1):min(m,n+C.u,B.u+ν)
        gbmv!('N', n-j+C.u+1, A.l+A.u, 0, α, a+sz*(j-B.u-1)*sta, B.l+B.u+1-(j-ν+B.l), sta, b+sz*(j-1)*stb, β, c+sz*(j-1)*stc)
    end

    C
end


function gbmm!{T}(α,A::BandedMatrix{T},B::Matrix{T},β,C::Matrix{T})
    st=max(1,stride(A.data,2))
    n,ν=size(A)
    a=pointer(A.data)


    b=pointer(B)

    m=size(B,2)

    @assert size(C,1)==n
    @assert size(C,2)==m

    c=pointer(C)

    sz=sizeof(T)

    for j=1:m
        gbmv!('N',n,A.l,A.u,α,a,ν,st,b+(j-1)*sz*ν,β,c+(j-1)*sz*n)
    end
    C
end

function banded_axpy!(a::Number,X,Y::BandedMatrix)
    @assert size(X)==size(Y)
    @assert bandwidth(X,1) ≤ bandwidth(Y,1) && bandwidth(X,2) ≤ bandwidth(Y,2)
    for (k,j) in eachbandedindex(X)
        @inbounds Y.data[k-j+Y.u+1,j]+=a*unsafe_getindex(X,k,j)
    end
    Y
end


function banded_axpy!{T,BM<:BandedMatrix}(a::Number,X,S::SubArray{T,2,BM})
    @assert size(X)==size(S)

    Y=parent(S)
    shft=bandshift(S)

    @assert 0 ≤ bandwidth(X,1) ≤ bandwidth(Y,1)-shft && 0 ≤ bandwidth(X,2) ≤ bandwidth(Y,2)+shft

    kr,jr=parentindexes(S)
    for (k,j) in eachbandedindex(X)
        @inbounds Y.data[kr[k]-jr[j]+Y.u+1,jr[j]]+=a*unsafe_getindex(X,k,j)
    end

    S
end

Base.BLAS.axpy!(a::Number,X::BandedMatrix,Y::BandedMatrix) =
    banded_axpy!(a,X,Y)

Base.BLAS.axpy!{T,BM<:BandedMatrix}(a::Number,X::BandedMatrix,S::SubArray{T,2,BM}) =
    banded_axpy!(a,X,S)

function Base.BLAS.axpy!{T1,T2,BM1<:BandedMatrix,BM2<:BandedMatrix}(a::Number,
                                                           X::SubArray{T1,2,BM1},
                                                           Y::SubArray{T2,2,BM2})
    if bandwidth(X,1) < 0
        jr=1-bandwidth(X,1):size(X,2)
        banded_axpy!(a,sub(X,:,jr),sub(Y,:,jr))
    elseif bandwidth(X,2) < 0
        kr=1-bandwidth(X,2):size(X,1)
        banded_axpy!(a,sub(X,kr,:),sub(Y,kr,:))
    else
        banded_axpy!(a,X,Y)
    end
end

function Base.BLAS.axpy!{T,BM<:BandedMatrix}(a::Number,X::SubArray{T,2,BM},Y::BandedMatrix)
    if bandwidth(X,1) < 0
        jr=1-bandwidth(X,1):size(X,2)
        banded_axpy!(a,sub(X,:,jr),sub(Y,:,jr))
    elseif bandwidth(X,2) < 0
        kr=1-bandwidth(X,2):size(X,1)
        banded_axpy!(a,sub(X,kr,:),sub(Y,kr,:))
    else
        banded_axpy!(a,X,Y)
    end
end

function Base.BLAS.axpy!(a::Number,X::BandedMatrix,Y::AbstractMatrix)
    @assert size(X)==size(Y)
    for (k,j) in eachbandedindex(X)
        @inbounds Y[k,j]+=a*unsafe_getindex(X,k,j)
    end
    Y
end






## A_mul_B! overrides

Base.A_mul_B!(C::Matrix,A::BandedMatrix,B::Matrix)=gbmm!(1.0,A,B,0.,C)

## Matrix*Vector Multiplicaiton



Base.A_mul_B!(c::Vector,A::BandedMatrix,b::Vector)=BLAS.gbmv!('N',A.m,A.l,A.u,1.0,A.data,b,0.,c)



## Matrix*Matrix Multiplication


Base.A_mul_B!(C::BandedMatrix,A::BandedMatrix,B::BandedMatrix)=gbmm!(1.0,A,B,0.0,C)
