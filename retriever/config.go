package retriever

import (
	"time"

	"github.com/Layr-Labs/eigenda/common"
	"github.com/Layr-Labs/eigenda/common/geth"
	"github.com/Layr-Labs/eigenda/encoding/kzg"
	"github.com/Layr-Labs/eigenda/indexer"
	"github.com/Layr-Labs/eigenda/retriever/flags"
	"github.com/urfave/cli"
)

type Config struct {
	EncoderConfig   kzg.KzgConfig
	EthClientConfig geth.EthClientConfig
	LoggerConfig    common.LoggerConfig
	IndexerConfig   indexer.Config
	MetricsConfig   MetricsConfig

	IndexerDataDir                string
	Timeout                       time.Duration
	NumConnections                int
	BLSOperatorStateRetrieverAddr string
	EigenDAServiceManagerAddr     string
	GraphUrl                      string
	UseGraph                      bool
}

func NewConfig(ctx *cli.Context) (*Config, error) {
	loggerConfig, err := common.ReadLoggerCLIConfig(ctx, flags.FlagPrefix)
	if err != nil {
		return nil, err
	}
	return &Config{
		EncoderConfig:   kzg.ReadCLIConfig(ctx),
		EthClientConfig: geth.ReadEthClientConfig(ctx),
		LoggerConfig:    *loggerConfig,
		IndexerConfig:   indexer.ReadIndexerConfig(ctx),
		MetricsConfig: MetricsConfig{
			HTTPPort: ctx.GlobalString(flags.MetricsHTTPPortFlag.Name),
		},
		IndexerDataDir:                ctx.GlobalString(flags.IndexerDataDirFlag.Name),
		Timeout:                       ctx.Duration(flags.TimeoutFlag.Name),
		NumConnections:                ctx.Int(flags.NumConnectionsFlag.Name),
		BLSOperatorStateRetrieverAddr: ctx.GlobalString(flags.BlsOperatorStateRetrieverFlag.Name),
		EigenDAServiceManagerAddr:     ctx.GlobalString(flags.EigenDAServiceManagerFlag.Name),
		GraphUrl:                      ctx.GlobalString(flags.GraphUrlFlag.Name),
		UseGraph:                      ctx.GlobalBool(flags.UseGraphFlag.Name),
	}, nil
}
