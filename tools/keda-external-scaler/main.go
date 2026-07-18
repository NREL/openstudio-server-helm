package main

import (
	"context"
	"errors"
	"fmt"
	"log"
	"math"
	"net"
	"os"
	"strconv"
	"strings"
	"time"

	pb "github.com/kedacore/keda/v2/pkg/scalers/externalscaler"
	"github.com/redis/go-redis/v9"
	"google.golang.org/grpc"
	appsv1 "k8s.io/api/apps/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/client-go/kubernetes"
	"k8s.io/client-go/rest"
)

type config struct {
	port int

	targetNamespace  string
	targetDeployment string

	redisAddress  string
	redisPassword string
	queueNames    []string

	metricName            string
	targetValue           int64
	activationTargetValue int64

	queueLengthPerWorker int64
	activationQueueDepth int64

	minReadyPercent  int64
	maxScaleStepPods int64
	maxScaleStepPct  int64

	streamInterval time.Duration
}

type scaler struct {
	pb.UnimplementedExternalScalerServer

	cfg      config
	redis    *redis.Client
	kube     *kubernetes.Clientset
	hasKube  bool
	shutdown chan struct{}
}

func main() {
	cfg, err := loadConfig()
	if err != nil {
		log.Fatalf("config error: %v", err)
	}

	s := &scaler{
		cfg:      cfg,
		redis:    redis.NewClient(&redis.Options{Addr: cfg.redisAddress, Password: cfg.redisPassword}),
		shutdown: make(chan struct{}),
	}

	if kc, err := inClusterKubeClient(); err == nil {
		s.kube = kc
		s.hasKube = true
	} else {
		log.Printf("kube client unavailable, readiness gate will be skipped: %v", err)
	}

	if err := s.redis.Ping(context.Background()).Err(); err != nil {
		log.Printf("redis ping failed at startup: %v", err)
	}

	lis, err := net.Listen("tcp", fmt.Sprintf(":%d", cfg.port))
	if err != nil {
		log.Fatalf("listen failed: %v", err)
	}

	grpcServer := grpc.NewServer()
	pb.RegisterExternalScalerServer(grpcServer, s)

	log.Printf("starting external scaler on :%d metric=%s target=%d activationTarget=%d queueNames=%s deployment=%s/%s",
		cfg.port, cfg.metricName, cfg.targetValue, cfg.activationTargetValue, strings.Join(cfg.queueNames, ","), cfg.targetNamespace, cfg.targetDeployment)

	if err := grpcServer.Serve(lis); err != nil {
		log.Fatalf("grpc serve failed: %v", err)
	}
}

func (s *scaler) IsActive(ctx context.Context, _ *pb.ScaledObjectRef) (*pb.IsActiveResponse, error) {
	depth, desired, _, _, err := s.computeDesiredReplicas(ctx)
	if err != nil {
		return nil, err
	}
	isActive := depth >= s.cfg.activationQueueDepth && desired >= s.cfg.activationTargetValue
	return &pb.IsActiveResponse{Result: isActive}, nil
}

func (s *scaler) StreamIsActive(ref *pb.ScaledObjectRef, stream grpc.ServerStreamingServer[pb.IsActiveResponse]) error {
	t := time.NewTicker(s.cfg.streamInterval)
	defer t.Stop()

	for {
		resp, err := s.IsActive(stream.Context(), ref)
		if err != nil {
			return err
		}
		if err := stream.Send(resp); err != nil {
			return err
		}

		select {
		case <-stream.Context().Done():
			return nil
		case <-s.shutdown:
			return nil
		case <-t.C:
		}
	}
}

func (s *scaler) GetMetricSpec(context.Context, *pb.ScaledObjectRef) (*pb.GetMetricSpecResponse, error) {
	return &pb.GetMetricSpecResponse{
		MetricSpecs: []*pb.MetricSpec{{
			MetricName: s.cfg.metricName,
			TargetSize: s.cfg.targetValue,
		}},
	}, nil
}

func (s *scaler) GetMetrics(ctx context.Context, req *pb.GetMetricsRequest) (*pb.GetMetricsResponse, error) {
	depth, desired, ready, currentDesired, err := s.computeDesiredReplicas(ctx)
	if err != nil {
		return nil, err
	}

	log.Printf("metrics depth=%d desired=%d ready=%d currentDesired=%d target=%d", depth, desired, ready, currentDesired, s.cfg.targetValue)
	return &pb.GetMetricsResponse{
		MetricValues: []*pb.MetricValue{{
			MetricName:  req.GetMetricName(),
			MetricValue: desired,
		}},
	}, nil
}

func (s *scaler) computeDesiredReplicas(ctx context.Context) (queueDepth int64, desiredReplicas int64, readyReplicas int64, currentDesired int64, err error) {
	queueDepth, err = s.queueDepth(ctx)
	if err != nil {
		return 0, 0, 0, 0, err
	}

	queueDrivenDesired := int64(math.Ceil(float64(queueDepth) / float64(max64(1, s.cfg.queueLengthPerWorker))))
	if queueDepth < s.cfg.activationQueueDepth {
		queueDrivenDesired = 0
	}

	dep, depErr := s.getTargetDeployment(ctx)
	if depErr != nil {
		// Fall back to queue-only behavior if deployment status cannot be read.
		return queueDepth, max64(queueDrivenDesired, 0), 0, 0, nil
	}

	if dep.Spec.Replicas != nil {
		currentDesired = int64(*dep.Spec.Replicas)
	}
	readyReplicas = int64(dep.Status.ReadyReplicas)
	desiredReplicas = s.applyReadinessGate(queueDrivenDesired, readyReplicas, currentDesired)
	if desiredReplicas < 0 {
		desiredReplicas = 0
	}
	return queueDepth, desiredReplicas, readyReplicas, currentDesired, nil
}

func (s *scaler) applyReadinessGate(queueDesired, ready, currentDesired int64) int64 {
	if currentDesired <= 0 {
		return queueDesired
	}

	readyPct := (ready * 100) / currentDesired
	if queueDesired > currentDesired && readyPct < s.cfg.minReadyPercent {
		// Freeze upward movement until the fleet catches up.
		return currentDesired
	}

	maxAllowedByPods := currentDesired + max64(1, s.cfg.maxScaleStepPods)
	maxAllowedByPct := currentDesired + int64(math.Ceil(float64(currentDesired)*float64(max64(1, s.cfg.maxScaleStepPct))/100.0))
	maxAllowed := min64(maxAllowedByPods, maxAllowedByPct)
	if queueDesired > maxAllowed {
		return maxAllowed
	}
	return queueDesired
}

func (s *scaler) queueDepth(ctx context.Context) (int64, error) {
	var total int64
	for _, q := range s.cfg.queueNames {
		key := "resque:queue:" + q
		n, err := s.redis.LLen(ctx, key).Result()
		if err != nil {
			return 0, fmt.Errorf("redis LLEN %s failed: %w", key, err)
		}
		total += n
	}
	return total, nil
}

func (s *scaler) getTargetDeployment(ctx context.Context) (*appsv1.Deployment, error) {
	if !s.hasKube || s.kube == nil {
		return nil, errors.New("kube client unavailable")
	}
	return s.kube.AppsV1().Deployments(s.cfg.targetNamespace).Get(ctx, s.cfg.targetDeployment, metav1.GetOptions{})
}

func inClusterKubeClient() (*kubernetes.Clientset, error) {
	cfg, err := rest.InClusterConfig()
	if err != nil {
		return nil, err
	}
	return kubernetes.NewForConfig(cfg)
}

func loadConfig() (config, error) {
	cfg := config{
		port:                  intFromEnv("EXTERNAL_SCALER_PORT", 9090),
		targetNamespace:       firstNonEmpty(os.Getenv("TARGET_NAMESPACE"), "default"),
		targetDeployment:      os.Getenv("TARGET_DEPLOYMENT"),
		redisAddress:          os.Getenv("REDIS_ADDRESS"),
		redisPassword:         os.Getenv("REDIS_PASSWORD"),
		queueNames:            splitCSV(firstNonEmpty(os.Getenv("QUEUE_NAMES"), "simulations,requeued")),
		metricName:            firstNonEmpty(os.Getenv("METRIC_NAME"), "worker_queue_pressure"),
		targetValue:           int64FromEnv("TARGET_VALUE", 1),
		activationTargetValue: int64FromEnv("ACTIVATION_TARGET_VALUE", 1),
		queueLengthPerWorker:  int64FromEnv("QUEUE_LENGTH_PER_WORKER", 1),
		activationQueueDepth:  int64FromEnv("ACTIVATION_QUEUE_LENGTH", 1),
		minReadyPercent:       int64FromEnv("READY_GATE_MIN_PERCENT", 95),
		maxScaleStepPods:      int64FromEnv("MAX_SCALE_STEP_PODS", 32),
		maxScaleStepPct:       int64FromEnv("MAX_SCALE_STEP_PERCENT", 200),
		streamInterval:        time.Duration(intFromEnv("STREAM_INTERVAL_SECONDS", 15)) * time.Second,
	}

	if cfg.targetDeployment == "" {
		return cfg, errors.New("TARGET_DEPLOYMENT is required")
	}
	if cfg.redisAddress == "" {
		return cfg, errors.New("REDIS_ADDRESS is required")
	}
	if len(cfg.queueNames) == 0 {
		return cfg, errors.New("QUEUE_NAMES resolved to an empty list")
	}
	return cfg, nil
}

func intFromEnv(key string, def int) int {
	raw := strings.TrimSpace(os.Getenv(key))
	if raw == "" {
		return def
	}
	v, err := strconv.Atoi(raw)
	if err != nil {
		return def
	}
	return v
}

func int64FromEnv(key string, def int64) int64 {
	raw := strings.TrimSpace(os.Getenv(key))
	if raw == "" {
		return def
	}
	v, err := strconv.ParseInt(raw, 10, 64)
	if err != nil {
		return def
	}
	return v
}

func splitCSV(s string) []string {
	var out []string
	for _, part := range strings.Split(s, ",") {
		p := strings.TrimSpace(part)
		if p != "" {
			out = append(out, p)
		}
	}
	return out
}

func firstNonEmpty(v, def string) string {
	if strings.TrimSpace(v) == "" {
		return def
	}
	return strings.TrimSpace(v)
}

func max64(a, b int64) int64 {
	if a > b {
		return a
	}
	return b
}

func min64(a, b int64) int64 {
	if a < b {
		return a
	}
	return b
}
