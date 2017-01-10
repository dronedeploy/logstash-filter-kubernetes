.PHONY : init clean package test

GEM_NAME := "logstash-filter-kubernetes-metadata"

clean:
	-minikube delete

init: clean 
	minikube start --extra-config apiserver.InsecureBindAddress=0.0.0.0
	@sleep 3
	kubectl create -f test/hello.pod.yml

package:
	docker run --rm -v $(CURDIR):/src -w "/src" jruby:1.7.23 gem build $(GEM_NAME).gemspec

test:
	docker run -it --rm \
		-e "KUBE_API=http://$(shell minikube ip):8080" \
		-v $(CURDIR):/src \
		logstash:2.3.4 \
		/src/test/docker-entrypoint.sh
