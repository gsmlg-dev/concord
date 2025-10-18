import Config

# 从环境变量读取节点名称，以便为每个节点创建独立的数据目录
node_name = System.get_env("NODE_NAME", "node")

# 为我们自己的 :concord 应用提供所有必要的配置
config :concord,
  # 这是 :ra 集群的全局唯一名称
  cluster_name: :concord_cluster,
  # 这是 Raft 存储日志和快照的目录
  data_dir: Path.join(System.tmp_dir!(), "concord_data/#{node_name}")

# 为 libcluster 提供集群发现策略
config :libcluster,
  topologies: [
    concord_gossip: [
      strategy: Cluster.Strategy.Gossip
    ]
  ]
