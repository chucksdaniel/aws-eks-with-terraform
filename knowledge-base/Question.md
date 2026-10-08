## Question about the Security

In a staging or production environment, What should be the standard way to connect to the kubernetes cluster?
- VPN: A project to configure the site-to-site VPN on AWS platform if I am using the VPN connection method

I noticed that when I run the `kubectl get nodes` I got the nodes available on the cluster. Now the role has <none> what does that mean. and also the node private IP contain 2 IPs address.

Base on the answer, in my workplace, we have a k8s cluster provisioned with kubeadm and now the devops engineer is handing it over to me the cluster is provisioned on aws ec2 how am I going to authenticate and also access the cluster


`kubectl get ns` will output

```bash
NAME              STATUS   AGE
default           Active   20h
kube-node-lease   Active   20h
kube-public       Active   20h
kube-system       Active   20h
```
What are they and what do they do?
