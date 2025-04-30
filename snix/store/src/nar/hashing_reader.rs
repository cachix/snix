use std::{
    io::Result,
    pin::Pin,
    task::{Context, Poll, ready},
};

use md5::{Digest, digest::DynDigest};
use nix_compat::nixhash::{HashAlgo, NixHash};
use pin_project_lite::pin_project;
use tokio::io::{AsyncRead, ReadBuf};

pin_project! {
    /// AsyncRead implementation with a type-erased hasher.
    ///
    /// After it's read the bytes from the underlying reader, it can
    /// produce the NixHash value corresponding to the Digest that it's been
    /// constructed with.
    ///
    /// Because we are type-erasing the underlying Digest, it uses dynamic dispatch
    /// and boxing. While it may seem like it could be slow, in practice it's used
    /// in IO-bound workloads so the slowdown should be negligible.
    ///
    /// On the other hand it greatly improves ergonomics of using different hashing
    /// algorithms and retrieving the corresponding NixHash values.
    pub struct HashingReader<R> {
        #[pin]
        reader: R,
        digest: Box<dyn ToHash>,
    }
}

/// Utility trait that simplifies digesting different hashes.
///
/// The main benefit is that each corresponding impl produces its corresponding
/// NixHash value as opposed to a lower level byte slice.
trait ToHash: DynDigest + Send {
    fn consume(self: Box<Self>) -> NixHash;
}

impl ToHash for sha1::Sha1 {
    fn consume(self: Box<Self>) -> NixHash {
        NixHash::Sha1(self.finalize().to_vec().try_into().expect("Snix bug"))
    }
}

impl ToHash for sha2::Sha256 {
    fn consume(self: Box<Self>) -> NixHash {
        NixHash::Sha256(self.finalize().to_vec().try_into().expect("Snix bug"))
    }
}

impl ToHash for sha2::Sha512 {
    fn consume(self: Box<Self>) -> NixHash {
        NixHash::Sha512(Box::new(
            self.finalize().to_vec().try_into().expect("Snix bug"),
        ))
    }
}

impl ToHash for md5::Md5 {
    fn consume(self: Box<Self>) -> NixHash {
        NixHash::Md5(self.finalize().to_vec().try_into().expect("Snix bug"))
    }
}

impl<R> HashingReader<R> {
    /// Given a NixHash, creates a HashingReader that uses the same hashing algorithm.
    pub fn new_with_algo(algo: HashAlgo, reader: R) -> Self {
        match algo {
            HashAlgo::Md5 => HashingReader::new::<md5::Md5>(reader),
            HashAlgo::Sha1 => HashingReader::new::<sha1::Sha1>(reader),
            HashAlgo::Sha256 => HashingReader::new::<sha2::Sha256>(reader),
            HashAlgo::Sha512 => HashingReader::new::<sha2::Sha512>(reader),
        }
    }
    fn new<D: ToHash + Digest + 'static>(reader: R) -> Self {
        HashingReader {
            reader,
            digest: Box::new(D::new()),
        }
    }

    /// Returns the [`NixHash`] of the data that's been read from this reader.
    pub fn consume(self) -> NixHash {
        self.digest.consume()
    }
}

impl<R: AsyncRead> AsyncRead for HashingReader<R> {
    fn poll_read(
        self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        buf: &mut ReadBuf<'_>,
    ) -> Poll<Result<()>> {
        let me = self.project();
        let filled_length = buf.filled().len();
        ready!(me.reader.poll_read(cx, buf))?;
        me.digest.update(&buf.filled()[filled_length..]);
        Poll::Ready(Ok(()))
    }
}
