#include <omnetpp.h>

class Animator : public cSimpleModule
{
    virtual void initialize();
    virtual void handleMessage(cMessage *msg);
};

Define_Module(Animator);

void Animator::initialize()
{
    scheduleAt(simTime(), new cMessage());
}

void Animator::handleMessage(cMessage *msg)
{
    cFigure *figure = getParentModule()->getCanvas()->findFigureRecursively("root");
    figure->rotate(0.01, 200, 200);
    figure->scale(0.997, 0.997);

    cOvalFigure *oval = check_and_cast<cOvalFigure*>(getParentModule()->getCanvas()->findFigureRecursively("oval1"));
    int w = (int)(simTime().dbl())%20;
    oval->setLineWidth(w);

    oval->rotate(-0.005, 500, 150);
	
	
	cPathFigure *path = check_and_cast<cPathFigure*>(getParentModule()->getCanvas()->findFigureRecursively("path1"));
	
	path->move(sin(simTime().dbl() / 10.0) * 2, 0);
	
    scheduleAt(simTime()+1, msg);
}

