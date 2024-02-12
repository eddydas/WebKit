/*
 * Copyright (C) 2024 Apple Inc. All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions
 * are met:
 * 1. Redistributions of source code must retain the above copyright
 *    notice, this list of conditions and the following disclaimer.
 * 2. Redistributions in binary form must reproduce the above copyright
 *    notice, this list of conditions and the following disclaimer in the
 *    documentation and/or other materials provided with the distribution.
 *
 * THIS SOFTWARE IS PROVIDED BY APPLE INC. AND ITS CONTRIBUTORS ``AS IS''
 * AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO,
 * THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
 * PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL APPLE INC. OR ITS CONTRIBUTORS
 * BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
 * CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
 * SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
 * INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
 * CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
 * ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF
 * THE POSSIBILITY OF SUCH DAMAGE.
 */

#pragma once

#if ENABLE(MODEL_PROCESS)

#include "Connection.h"
#include "LayerHostingContext.h"
#include "MessageReceiverMap.h"
#include "ModelConnectionToWebProcessMessages.h"
#include "RenderingBackendIdentifier.h"
#include "ScopedActiveMessageReceiveQueue.h"
#include "WebPageProxyIdentifier.h"
#include <WebCore/Model.h>
#include <WebCore/PageIdentifier.h>
#include <WebCore/ProcessIdentifier.h>
#include <WebCore/ProcessIdentity.h>
#include <pal/SessionID.h>
#include <wtf/Logger.h>
#include <wtf/MachSendRight.h>
#include <wtf/ThreadSafeRefCounted.h>

#if ENABLE(IPC_TESTING_API)
#include "IPCTester.h"
#endif

namespace WTF {
enum class Critical : bool;
enum class Synchronous : bool;
}

namespace WebCore {
class SecurityOrigin;
class SecurityOriginData;
}

namespace WebKit {

class TmpModelPlayer;
class ModelProcess;
struct ModelProcessConnectionParameters;

class ModelConnectionToWebProcess
    : public ThreadSafeRefCounted<ModelConnectionToWebProcess, WTF::DestructionThread::Main>
    , IPC::Connection::Client {
public:
    static Ref<ModelConnectionToWebProcess> create(ModelProcess&, WebCore::ProcessIdentifier, PAL::SessionID, IPC::Connection::Handle&&, ModelProcessConnectionParameters&&);
    virtual ~ModelConnectionToWebProcess();

    IPC::Connection& connection() { return m_connection.get(); }
    IPC::MessageReceiverMap& messageReceiverMap() { return m_messageReceiverMap; }
    ModelProcess& modelProcess() { return m_modelProcess.get(); }
    WebCore::ProcessIdentifier webProcessIdentifier() const { return m_webProcessIdentifier; }

    PAL::SessionID sessionID() const { return m_sessionID; }

    Logger& logger();

    const WebCore::ProcessIdentity& webProcessIdentity() const { return m_webProcessIdentity; }

    bool allowsExitUnderMemoryPressure() const;

    void lowMemoryHandler(WTF::Critical, WTF::Synchronous);

    static uint64_t objectCountForTesting() { return gObjectCountForTesting; }

private:
    ModelConnectionToWebProcess(ModelProcess&, WebCore::ProcessIdentifier, PAL::SessionID, IPC::Connection::Handle&&, ModelProcessConnectionParameters&&);

#if HAVE(VISIBILITY_PROPAGATION_VIEW)
    void createVisibilityPropagationContextForPage(WebPageProxyIdentifier, WebCore::PageIdentifier, bool canShowWhileLocked);
    void destroyVisibilityPropagationContextForPage(WebPageProxyIdentifier, WebCore::PageIdentifier);
#endif

    void configureLoggingChannel(const String&, WTFLogChannelState, WTFLogLevel);
        
    // EDDY
    void loadModel(RenderingBackendIdentifier identifier, Ref<WebCore::Model>&&);

    // IPC::Connection::Client
    void didClose(IPC::Connection&) final;
    void didReceiveInvalidMessage(IPC::Connection&, IPC::MessageName) final;
    void didReceiveMessage(IPC::Connection&, IPC::Decoder&) final;
    bool didReceiveSyncMessage(IPC::Connection&, IPC::Decoder&, UniqueRef<IPC::Encoder>&) final;

    bool dispatchMessage(IPC::Connection&, IPC::Decoder&);
    bool dispatchSyncMessage(IPC::Connection&, IPC::Decoder&, UniqueRef<IPC::Encoder>&);

    static uint64_t gObjectCountForTesting;

    RefPtr<Logger> m_logger;

    Ref<IPC::Connection> m_connection;
    IPC::MessageReceiverMap m_messageReceiverMap;
    Ref<ModelProcess> m_modelProcess;
    const WebCore::ProcessIdentifier m_webProcessIdentifier;
    const WebCore::ProcessIdentity m_webProcessIdentity;
    PAL::SessionID m_sessionID;
#if HAVE(AUDIT_TOKEN)
    std::optional<audit_token_t> m_presentingApplicationAuditToken;
#endif

#if HAVE(VISIBILITY_PROPAGATION_VIEW)
    HashMap<std::pair<WebPageProxyIdentifier, WebCore::PageIdentifier>, std::unique_ptr<LayerHostingContext>> m_visibilityPropagationContexts;
#endif

#if ENABLE(IPC_TESTING_API)
    IPCTester m_ipcTester;
#endif

    using TmpModelPlayerMap = HashMap<RenderingBackendIdentifier, Ref<TmpModelPlayer>>;
    TmpModelPlayerMap m_tmpModelPlayers;
};

} // namespace WebKit





namespace WebCore {
// class Model;
//class REModel;
//class REModelLoader;
}

namespace WebKit {

class TmpModelPlayer final : public ThreadSafeRefCounted<TmpModelPlayer>
//, public WebCore::REModelLoaderClient
{
public:
    static Ref<TmpModelPlayer> create();
    ~TmpModelPlayer();

    void load(WebCore::Model&);

//    void updateTransform();
//    void updateOpacity();
//
//    float cameraPitch() const { return m_pitch; }
//    void setCameraPitch(float pitch) { m_pitch = pitch; }
//    float cameraYaw() const { return m_yaw; }
//    void setCameraYaw(float yaw) { m_yaw = yaw; }

//    void setLayer(WKSeparatedModelLayer *);
//    WKSeparatedModelLayer *layer() const;

//    void didMoveToWindow();

private:
    TmpModelPlayer();

//    // WebCore::REModelLoaderClient overrides.
//    virtual void didFinishLoading(WebCore::REModelLoader&, Ref<WebCore::REModel>) final;
//    virtual void didFailLoading(WebCore::REModelLoader&, const WebCore::ResourceError&) final;

//    void startAnimating();
//
//    CGFloat effectivePointsPerMeter();

//    WeakObjCPtr<WKSeparatedModelLayer> m_layer;
//    RefPtr<WebCore::REModelLoader> m_loader;
//    RefPtr<WebCore::REModel> m_model;
//    simd_float3 m_originalBoundingBoxExtents { simd_make_float3(0, 0, 0) };
//    float m_pitch { 0 };
//    float m_yaw { 0 };
//    REAnimationPlaybackToken m_animationPlaybackToken { kInvalidAnimationToken };
    
    std::unique_ptr<LayerHostingContext> m_inlineLayerHostingContext;
    RetainPtr<CALayer> m_layer;
};

}
#endif // ENABLE(MODEL_PROCESS)
