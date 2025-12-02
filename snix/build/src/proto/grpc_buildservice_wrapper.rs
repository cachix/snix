use crate::buildservice::BuildService;
use futures::stream::BoxStream;
use futures::StreamExt;
use std::ops::Deref;
use tonic::async_trait;

use super::{BuildEvent, BuildRequest};

/// Implements the gRPC server trait ([crate::proto::build_service_server::BuildService]
/// for anything implementing [BuildService].
pub struct GRPCBuildServiceWrapper<BUILD> {
    inner: BUILD,
}

impl<BUILD> GRPCBuildServiceWrapper<BUILD> {
    pub fn new(build_service: BUILD) -> Self {
        Self {
            inner: build_service,
        }
    }
}

#[async_trait]
impl<BUILD> crate::proto::build_service_server::BuildService for GRPCBuildServiceWrapper<BUILD>
where
    BUILD: Deref<Target = dyn BuildService> + Send + Sync + 'static,
{
    type DoBuildStream = BoxStream<'static, Result<BuildEvent, tonic::Status>>;

    async fn do_build(
        &self,
        request: tonic::Request<BuildRequest>,
    ) -> Result<tonic::Response<Self::DoBuildStream>, tonic::Status> {
        let request = TryInto::<crate::buildservice::BuildRequest>::try_into(request.into_inner())
            .map_err(|err| tonic::Status::new(tonic::Code::InvalidArgument, err.to_string()))?;

        let stream = self.inner.do_build(request);

        // Map the stream to convert BuildEvent to proto BuildEvent
        let proto_stream = stream.map(|result| {
            result
                .map(|event| event.into())
                .map_err(|e| tonic::Status::internal(e.to_string()))
        });

        Ok(tonic::Response::new(Box::pin(proto_stream)))
    }
}
