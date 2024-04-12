# local tests 
helm template test ./application    #uses current values.yaml file - faster than helm install 
helm install --dry-run --debug test ./application 

#after pushing code 
helm install -f ./values.yaml --dry-run --debug test seagits/application  