from collections import namedtuple

EpochLevel = namedtuple("EpochLevel", ["name", "level", "min", "max"])  


class Epoch:
    def __init__(self, epochs):        
        self.epochs = epochs

    def epoch(self, epoch):
        clear = False 
        for i,e in enumerate(self.epochs):
            if not clear and e.name == epoch:                
                self.epochs[i] = EpochLevel(e.name, e.level+1, e.min, e.max)
                assert e.level <= e.max or e.max == -1, "Epoch {} is out of range".format(e.name)
                clear = True
            elif clear:
                self.epochs[i] = EpochLevel(e.name, e.min, e.min, e.max)        
        self.print()

    def print(self):
        for e in self.epochs:
            print(e.name, e.level, end="\t")
        print()
    
def make_epoch(epochs):
    created_epochs = []
    for epoch in epochs:
        if type(epoch)==dict:
            name = list(epoch.keys())[0]
            min = epoch[name].get("min", 0)
            max = epoch[name].get("max", -1)
            epoch = EpochLevel(name, min, min, max)            
        else:
            epoch = EpochLevel(epoch, 0, 0, -1)
        created_epochs.append(epoch)    
    return Epoch(created_epochs)



if __name__ == "__main__":
    epochs = make_epoch(["train", "val", "test"])
    epochs.epoch("train")
    epochs.epoch("train")
    epochs.epoch("train")
    epochs.epoch("val")
    epochs.epoch("val")
    epochs.epoch("val")
    