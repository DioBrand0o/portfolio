# =============================================================================
# LOCALS - Génération dynamique des nodes
# =============================================================================

locals {
  controller_nodes = [
    for i in range(var.controller_count) : {
      name    = "c${i}"
      address = cidrhost(var.cluster_node_network, var.cluster_node_network_first_controller_hostnum + i)
    }
  ]

  worker_nodes = [
    for i in range(var.worker_count) : {
      name    = "w${i}"
      address = cidrhost(var.cluster_node_network, var.cluster_node_network_first_worker_hostnum + i)
    }
  ]

  common_machine_config = {
    machine = {
      features = {
        kubePrism = {
          enabled = true
          port    = 7445
        }
        hostDNS = {
          enabled              = true
          forwardKubeDNSToHost = true
        }
      }
      kernel = {
        modules = [
          {
            name       = "drbd"
            parameters = ["usermode_helper=disabled"]
          },
          {
            name = "drbd_transport_tcp"
          }
        ]
      }
    }
    cluster = {
      discovery = {
        enabled  = true
        registries = {
          kubernetes = {
            disabled = false
          }
          service = {
            disabled = true
          }
        }
      }
      network = {
        cni = {
          name = "none"
        }
      }
      proxy = {
        disabled = true
      }
    }
  }
}

# =============================================================================
# CONTROL PLANE VMs
# =============================================================================

resource "proxmox_virtual_environment_vm" "controller" {
  count           = var.controller_count
  name            = "${var.prefix}-${local.controller_nodes[count.index].name}"
  node_name       = "pve"
  tags            = sort(concat(var.tags, ["controller"]))
  stop_on_destroy = true
  bios            = "ovmf"
  machine         = "q35"
  scsi_hardware   = "virtio-scsi-single"
  
  operating_system {
    type = "l26"
  }
  
  cpu {
    type  = "host"
    cores = 2
  }
  
  memory {
    dedicated = 4 * 1024
  }
  
  vga {
    type = "qxl"
  }
  
  network_device {
    bridge = "vmbr1"
    mtu    = 1500
  }
  
  tpm_state {
    datastore_id = var.default-datastoreid
    version      = "v2.0"
  }
  
  efi_disk {
    datastore_id = var.default-datastoreid
    file_format  = "raw"
    type         = "4m"
  }
  
  # Clone depuis template Talos
  clone {
    vm_id = 999
    full  = true
  }
  
  disk {
    datastore_id = var.default-datastoreid
    interface    = "scsi0"
    iothread     = true
    ssd          = true
    discard      = "on"
    size         = 30
    file_format  = "raw"
  }
  
  agent {
    enabled = true
    trim    = true
  }
  
  initialization {
    datastore_id = var.default-datastoreid
    ip_config {
      ipv4 {
        address = "${local.controller_nodes[count.index].address}/24"
        gateway = var.cluster_node_network_gateway
      }
    }
  }
}

# =============================================================================
# WORKER VMs
# =============================================================================

resource "proxmox_virtual_environment_vm" "worker" {
  count           = var.worker_count
  name            = "${var.prefix}-${local.worker_nodes[count.index].name}"
  node_name       = "pve"
  tags            = sort(concat(var.tags, ["worker"]))
  stop_on_destroy = true
  bios            = "ovmf"
  machine         = "q35"
  scsi_hardware   = "virtio-scsi-single"
  
  operating_system {
    type = "l26"
  }
  
  cpu {
    type  = "host"
    cores = 4
  }
  
  memory {
    dedicated = 6 * 1024
  }
  
  vga {
    type = "qxl"
  }
  
  network_device {
    bridge = "vmbr1"
    mtu    = 1500
  }
  
  tpm_state {
    datastore_id = var.default-datastoreid
    version      = "v2.0"
  }
  
  efi_disk {
    datastore_id = var.default-datastoreid
    file_format  = "raw"
    type         = "4m"
  }
  
  # Clone depuis template Talos
  clone {
    vm_id = 999
    full  = true
  }
  
  disk {
    datastore_id = var.default-datastoreid
    interface    = "scsi0"
    iothread     = true
    ssd          = true
    discard      = "on"
    size         = 40
    file_format  = "raw"
  }
  
  # Disque supplémentaire pour stockage distribué
  disk {
    datastore_id = var.default-datastoreid
    interface    = "scsi1"
    iothread     = true
    ssd          = true
    discard      = "on"
    size         = 60
    file_format  = "raw"
  }
  
  agent {
    enabled = true
    trim    = true
  }
  
  initialization {
    datastore_id = var.default-datastoreid
    ip_config {
      ipv4 {
        address = "${local.worker_nodes[count.index].address}/24"
        gateway = var.cluster_node_network_gateway
      }
    }
  }
}

# =============================================================================
# TALOS & BOOTSTRAP
# =============================================================================

resource "talos_machine_secrets" "talos" {
  talos_version = "v${var.talos_version}"
}

data "talos_machine_configuration" "controller" {
  cluster_name       = var.cluster_name
  cluster_endpoint   = var.cluster_endpoint
  machine_secrets    = talos_machine_secrets.talos.machine_secrets
  machine_type       = "controlplane"
  talos_version      = "v${var.talos_version}"
  kubernetes_version = var.kubernetes_version
  examples           = false
  docs               = false
  config_patches = [
    yamlencode(local.common_machine_config),
    yamlencode({
      machine = {
        network = {
          interfaces = [
            {
              interface = "eth0"
              vip = {
                ip = var.cluster_vip
              }
            }
          ]
        }
      }
    }),
    yamlencode({
      cluster = {
        inlineManifests = concat([
          {
            name     = "spin"
            contents = <<-EOF
              apiVersion: node.k8s.io/v1
              kind: RuntimeClass
              metadata:
                name: wasmtime-spin-v2
              handler: spin
              EOF
          },
          {
            name = "cilium"
            contents = join("---\n", [
              data.helm_template.cilium.manifest,
              "# Source cilium.tf\n${local.cilium_external_lb_manifest}",
            ])
          },
          {
            name = "cert-manager"
            contents = join("---\n", [
              yamlencode({
                apiVersion = "v1"
                kind       = "Namespace"
                metadata = {
                  name = "cert-manager"
                }
              }),
              data.helm_template.cert_manager.manifest,
              "# Source cert-manager.tf\n${local.cert_manager_ingress_ca_manifest}",
            ])
          },
          {
            name     = "trust-manager"
            contents = data.helm_template.trust_manager.manifest
          },
          {
            name     = "reloader"
            contents = data.helm_template.reloader.manifest
          }
        ], var.argocd_enabled ? [
          {
            name = "argocd"
            contents = join("---\n", [
              yamlencode({
                apiVersion = "v1"
                kind       = "Namespace"
                metadata = {
                  name = local.argocd_namespace
                }
              }),
              data.helm_template.argocd.manifest,
              "# Source argocd.tf\n${local.argocd_manifest}",
            ])
          }
        ] : [])
      }
    }),
  ]
}

data "talos_machine_configuration" "worker" {
  cluster_name       = var.cluster_name
  cluster_endpoint   = var.cluster_endpoint
  machine_secrets    = talos_machine_secrets.talos.machine_secrets
  machine_type       = "worker"
  talos_version      = "v${var.talos_version}"
  kubernetes_version = var.kubernetes_version
  examples           = false
  docs               = false
  config_patches = [
    yamlencode(local.common_machine_config),
  ]
}

data "talos_client_configuration" "talos" {
  cluster_name         = var.cluster_name
  client_configuration = talos_machine_secrets.talos.client_configuration
  endpoints            = [for node in local.controller_nodes : node.address]
}

resource "talos_cluster_kubeconfig" "talos" {
  client_configuration = talos_machine_secrets.talos.client_configuration
  endpoint             = local.controller_nodes[0].address
  node                 = local.controller_nodes[0].address
  depends_on = [
    talos_machine_bootstrap.talos,
  ]
}

resource "talos_machine_configuration_apply" "controller" {
  count                       = var.controller_count
  client_configuration        = talos_machine_secrets.talos.client_configuration
  machine_configuration_input = data.talos_machine_configuration.controller.machine_configuration
  endpoint                    = local.controller_nodes[count.index].address
  node                        = local.controller_nodes[count.index].address
  config_patches = [
    yamlencode({
      machine = {
        network = {
          hostname    = local.controller_nodes[count.index].name
          nameservers = var.dns_serveurs
        }
        time = {
          servers = var.ntp_serveurs
        }
      }
    }),
  ]
  depends_on = [
    proxmox_virtual_environment_vm.controller,
  ]
}

resource "talos_machine_configuration_apply" "worker" {
  count                       = var.worker_count
  client_configuration        = talos_machine_secrets.talos.client_configuration
  machine_configuration_input = data.talos_machine_configuration.worker.machine_configuration
  endpoint                    = local.worker_nodes[count.index].address
  node                        = local.worker_nodes[count.index].address
  config_patches = [
    yamlencode({
      machine = {
        network = {
          hostname    = local.worker_nodes[count.index].name
          nameservers = var.dns_serveurs
        }
        time = {
          servers = var.ntp_serveurs
        }
        sysctls = {
          "net.ipv6.conf.all.disable_ipv6"      = "1"
          "net.ipv6.conf.default.disable_ipv6"  = "1"
          "net.ipv6.conf.lo.disable_ipv6"       = "1"
        }
      }
    }),
  ]
  depends_on = [
    proxmox_virtual_environment_vm.worker,
  ]
}

resource "talos_machine_bootstrap" "talos" {
  client_configuration = talos_machine_secrets.talos.client_configuration
  endpoint             = local.controller_nodes[0].address
  node                 = local.controller_nodes[0].address
  depends_on = [
    talos_machine_configuration_apply.controller,
  ]
}
